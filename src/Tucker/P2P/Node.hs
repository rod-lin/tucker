module Tucker.P2P.Node where

import Data.List
import Data.Word
import Data.Foldable as FD
import qualified Data.Set as SET
import qualified Data.Set.Ordered as OSET

import qualified Data.ByteString as BSR
import qualified Data.ByteString.Char8 as BS

import Control.Monad
import Control.Exception
import Control.Concurrent
import Control.Monad.Morph
import Control.Monad.Trans.Resource

import Network.Socket

import Tucker.DB
import Tucker.Enc
import Tucker.Msg
import Tucker.Conf
import Tucker.Atom
import Tucker.Util
import Tucker.Transport
import qualified Tucker.Lock as LK

import Tucker.Storage.Chain

-- two parts
-- 1. main old tree, most common chain for all blocks
-- 2. side chains, side chains rooted from main tree

-- an environment shared among a main loop
data MainLoopEnv =
    MainLoopEnv {
        main_proc_tid :: ThreadId,
        global_conf   :: TCKRConf,

        timeout_s     :: Int, -- timeout in sec
        node_list     :: Atom [Node],

        gc_interv     :: Integer, -- in ms

        -- io_lock       :: LK.Lock,
        io_buf        :: Atom [String],

        chain_lock    :: LK.Lock,
        block_chain   :: Atom BlockChain
    }

data RouterAction
    = StopProp -- stop the propagation of the message
    | DumpMe -- dump the current handler
    | UpdateMe NodeAction -- update to a new action

instance Eq RouterAction where
    StopProp == StopProp = True
    DumpMe   == DumpMe   = True
    _        == _        = False

data NodeAction
    = NormalAction { handler :: ActionHandle }
    | NoAction

type ActionHandle = MainLoopEnv -> Node -> MsgHead -> IO [RouterAction]

-- progress of a download task
-- Progress received total
-- all in bytes
data Progress = Progress Integer Integer

instance Show Progress where
    show (Progress recv'd total) =
        if total >= 0 then
            let perc = fi recv'd / fi total in
            printf "progress %d/%d(%f) received" recv'd total (perc :: Double)
        else
            printf "progress %d received" recv'd

instance Default Progress where
    def = Progress 0 0

data TransferState =
    TransferState {
        ping_delay         :: Word, -- in ms
        cur_progress       :: Progress, -- download progress on the current msg(when last_seen)
        last_seen          :: Timestamp,
        recv_buf           :: ByteString, -- currently downloaded part

        speed_test_begin   :: Timestamp,
        total_download     :: Word64, -- total download from speed_test_begin to now
        max_download_speed :: Word64 -- in bytes/s
    }

-- return if the ts1 is likely faster than ts2(GT) or other wise
compareTransState :: TransferState -> TransferState -> Ordering
compareTransState (TransferState {
    max_download_speed = ds1,
    ping_delay = ping1
}) (TransferState {
    max_download_speed = ds2,
    ping_delay = ping2
}) =
    case compare ds1 ds2 of
        EQ -> compare ping2 ping1 -- the result is reversed
        r -> r

instance Show TransferState where
    show ts = printf "TransferState {ping_delay=%v,cur_progress=%v,max_download_speed=%v}"
        (ping_delay ts) (show (cur_progress ts)) (max_download_speed ts)

instance Default TransferState where
    def = TransferState {
        ping_delay = maxBound,
        cur_progress = def,
        last_seen = 0,
        recv_buf = BSR.empty,

        speed_test_begin = 0,
        total_download = 0,
        max_download_speed = 0
    }

data Node =
    Node {
        conn_trans      :: Transport,
        incoming        :: Bool,

        thread_id       :: ThreadId,
        sock_addr       :: SockAddr,
        net_addr        :: NetAddr,
        vers_payload    :: VersionPayload,

        -- msg_list       :: Atom [MsgHead], -- prepend

        blacklist_time  :: Atom Int, -- how many times is the node blacklisted

        action_list     :: Atom [NodeAction],
        new_action      :: Atom [NodeAction],

        cur_trans_state :: Atom TransferState,

        alive           :: Atom Bool
    }

instance Eq Node where
    (Node { thread_id = t1 }) == (Node { thread_id = t2 })
        = t1 == t2

instance Ord Node where
    compare (Node { thread_id = t1 }) (Node { thread_id = t2 })
        = compare t1 t2

instance Show Node where
    show node =
        "node on " ++ show (sock_addr node)

-- used in spreading actions
-- a task can be anything specified for a action
-- that is going to be spreaded out
-- the task needs to be monoid for task combination
class Monoid t => NodeTask t where
    done :: MainLoopEnv -> Node -> t -> IO ()

taskFold :: NodeTask t => [t] -> Int -> [t]
taskFold ts n = map mconcat (foldList n ts)

data NullTask = NullTask

instance Monoid NullTask where
    mempty = NullTask
    mappend _ _ = NullTask

instance NodeTask NullTask where
    done e n t = return ()

envMsg :: MainLoopEnv -> String -> IO ()
envMsg env msg = do
    -- force eval
    -- let msg' = BS.pack ("env: " ++ msg)

    tLnM ("env: " ++ msg)

    -- LK.with (io_lock env) $ BS.putStrLn msg'

    -- appA (++ [ "env: " ++ msg ]) (io_buf env)
    -- putStrLn' $ "env: " ++ msg

envWarn :: MainLoopEnv -> String -> IO ()
envWarn env msg =
    tLnM (wss (Color Yellow False) ("env: " ++ msg))

initEnv :: TCKRConf -> ResIO MainLoopEnv
initEnv conf = do
    tid <- lift myThreadId

    node_list <- lift $ newA []
    -- io_lock <- lift $ LK.new
    io_buf <- lift $ newA []

    -- db_block <- openDB def (tckr_db_path conf) (tckr_ks_block conf)
    -- db_tx <- openDB def (tckr_db_path conf) (tckr_ks_tx conf)
    -- db_chain <- openDB def (tckr_db_path conf) (tckr_ks_chain conf)

    chain_lock <- lift $ LK.new
    block_chain <- initBlockChain conf >>= (lift . newA)

    return $ MainLoopEnv {
        main_proc_tid = tid,
        global_conf = conf,

        timeout_s = tckr_trans_timeout conf,
        node_list = node_list,
        gc_interv = tckr_gc_interval conf,

        -- io_lock = io_lock,
        io_buf = io_buf,

        chain_lock = chain_lock,
        block_chain = block_chain

        -- db_block = db_block,
        -- db_tx = db_tx,
        -- db_chain = db_chain
    }

initNode :: SockAddr -> Transport -> IO Node
initNode sock_addr trans = do
    timestamp    <- unixTimestamp

    -- vers_payload <- newA VersionPending -- version placeholder
    -- recv_buf       <- newA $ BSR.empty
    -- msg_list     <- newA []
    blacklist_time <- newA 0
    action_list    <- newA [] -- nodeDefaultActionList
    new_action     <- newA []

    trans_state    <- newA def

    alive          <- newA True

    return $ Node {
        conn_trans      = trans,
        incoming        = False,

        thread_id       = undefined,
        sock_addr       = sock_addr,
        net_addr        = undefined,
        vers_payload    = undefined,

        -- recv_buf       = recv_buf,
        -- msg_list     = msg_list,
        -- last_seen      = last_seen,
        -- cur_progress   = cur_progress,
        blacklist_time  = blacklist_time,

        action_list     = action_list,
        new_action      = new_action,

        -- ping_delay     = ping_delay,

        cur_trans_state = trans_state,

        alive           = alive
    }

envConf :: MainLoopEnv -> (TCKRConf -> t) -> t
envConf env field = field $ global_conf env

envAllNode :: MainLoopEnv -> IO [Node]
envAllNode = getA . node_list

envExit :: Exception e => MainLoopEnv -> e -> IO ()
envExit env e = throwTo (main_proc_tid env) e

nodeMsg :: MainLoopEnv -> Node -> String -> IO ()
nodeMsg env node msg = envMsg env $ (show node) ++ ": " ++ msg

nodeWarn :: MainLoopEnv -> Node -> String -> IO ()
nodeWarn env node msg = envWarn env $ (show node) ++ ": " ++ msg

nodeLastSeen :: Node -> IO Timestamp
nodeLastSeen node = last_seen <$> getA (cur_trans_state node)

nodeBlacklistTime :: Node -> IO Int
nodeBlacklistTime = getA . blacklist_time

nodeBlacklistInc :: Node -> IO Int
nodeBlacklistInc = appA (+1) . blacklist_time

nodeBlacklistDec :: Node -> IO Int
nodeBlacklistDec = appA (\c -> if c > 0 then c - 1 else 0) . blacklist_time

-- nodeBlacklistDec :: Node -> IO ()
-- nodeBlacklistDec node =
--     appA (-1) (blacklist_time node)

nodePrependActions :: Node -> [NodeAction] -> IO ()
nodePrependActions node new_actions =
    appA (new_actions ++) (new_action node) >> return ()

nodeNetAddr :: Node -> IO NetAddr
nodeNetAddr = return . net_addr

nodeTransState :: Node -> IO TransferState
nodeTransState = getA . cur_trans_state

nodeChangeTransState :: Node -> (TransferState -> TransferState) -> IO ()
nodeChangeTransState node f = appA f (cur_trans_state node) >> return ()

nodeNetDelay :: Node -> IO Word
nodeNetDelay node = ping_delay <$> getA (cur_trans_state node)

-- this function will filter out uninit nodes
envAllNetDelay :: Integral t => MainLoopEnv -> IO [t]
envAllNetDelay env =
    getA (node_list env) >>=
    mapM nodeNetDelay >>=
    (return . map fi . filter (/= maxBound))

-- spread actions to nodes except the ones in the black list
-- return [] if no available node is found
envSpreadActionExcept :: NodeTask t
                      => [Node] -> MainLoopEnv -> (t -> [NodeAction]) -> [t] -> IO [(Node, t)]
envSpreadActionExcept blacklist env gen_action tasks = do
    nodes <- getA (node_list env)

    alive_nodes <- flip filterM nodes $ \node -> do
        alive <- getA (alive node)
        tcount <- length <$> getA (action_list node)

        -- limit the maximum task load on one node
        return $
            alive && tcount <= envConf env tckr_node_max_task + 1 -- base handler

    -- filter out dead nodes

    states <- mapM nodeTransState nodes
    -- delays <- mapM nodeNetDelay nodes

    -- envMsg env $ "blacklist: " ++ show blacklist

    let sorted = sortBy (\(d1, _) (d2, _) -> compareTransState d2 d1)
                        (zip states alive_nodes)
        sorted_nodes =
            filter (`notElem` blacklist) $
            map snd sorted

        taskn = length tasks
        noden = length sorted_nodes

    -- envMsg env $ show sorted

    if noden == 0 then return []
    else do
        let (target_nodes, new_tasks) =
                if noden < taskn then
                    -- no enough node
                    (sorted_nodes, taskFold tasks noden)
                else
                    -- great, we have enough nodes
                    -- simply take n nodes
                    (take taskn sorted_nodes, tasks)

            assignment = zip target_nodes new_tasks

        -- assume length target_nodes == length new_tasks
        forM_ assignment $ \(node, task) -> do
            -- nodeMsg env node $ "prepending new action(s)"

            -- append new actions to each node
            nodePrependActions node (gen_action task)
            
        return assignment

envSpreadAction = envSpreadActionExcept []

envSpreadSimpleAction :: MainLoopEnv -> NodeAction -> Int -> IO [(Node, NullTask)]
envSpreadSimpleAction env action n =
    envSpreadAction env (const [action]) (replicate n NullTask)

envAppendNode :: MainLoopEnv -> Node -> IO ()
envAppendNode env node =
    appA (++ [node]) (node_list env) >> return ()

envAddBlock :: MainLoopEnv -> Node -> Block -> IO ()
envAddBlock env node block =
    envAddBlocks env node [block]

-- removing explicit reference to the block list
-- NOTE: may help reduce space leaks?
envAddBlocks :: MainLoopEnv -> Node -> [Block] -> IO ()
envAddBlocks env node =
    (>>= after) .
    (before >>=) .
    (flip (addBlocks proc))

    where
        before = LK.acquire (chain_lock env) >> getA (block_chain env)
        after chain = setA (block_chain env) chain >> LK.release (chain_lock env)
        proc block res =
            case res of
                Left err ->
                    error $ "error when adding block " ++ show block ++ ": " ++ show err
                
                Right _ ->
                    nodeMsg env node $ "block added: " ++ show block
