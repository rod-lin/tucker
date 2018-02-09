{-# LANGUAGE DuplicateRecordFields, ConstraintKinds #-}

-- block chain implementation

module Tucker.Chain.Object where

import Data.Int -- hiding (map, findIndex, null)
import Data.Word
import Data.Maybe
import Data.List hiding (map)
import qualified Data.Set as SET
import qualified Data.ByteString as BSR
import qualified Data.Set.Ordered as OSET

import Control.Monad
import Control.Monad.Loops
import Control.Applicative
import Control.Monad.Morph
import Control.Monad.Trans.Resource

import Control.Exception

import Debug.Trace

import Tucker.DB
import Tucker.Msg
import Tucker.Enc
import Tucker.Util
import Tucker.Auth
import Tucker.Conf
import Tucker.Error

-- data BlockTree = BlockTree [[Block]] deriving (Eq, Show)
-- data Block

-- type TreeHeight = Int

-- simple in-mem representation of block chain
-- Chain root blocks

-- a main chain is a Chain with root == nullHash256
-- a branch is a Chain with root /= nullHash256

-- data Chain = Chain {
--         root_hash :: Hash256,
--         chain     :: [Block]
--     } deriving (Eq, Show)

type Height = Word64
-- height starts from 0(genesis)

data Branch
    = BlockNode {
        prev_node  :: Maybe Branch,
        block_data :: Block,
        cur_height :: Height,
        acc_diff   :: Difficulty
    } deriving (Show)

instance Eq Branch where
    (BlockNode { block_data = b1 }) == (BlockNode { block_data = b2 })
        = b1 == b2

instance Ord Branch where
    compare (BlockNode { cur_height = h1 }) (BlockNode { cur_height = h2 })
        = compare h1 h2

-- Branches fork_point_hash last_nodes
-- type Branches = [Branch]
    -- last nodes of branches
    -- all branches can be traced back to a common fork point

data Chain =
    Chain {
        -- block db contains all valid blocks(blocks that can be linked to the tree)
        -- received(including those on the side branch)
        std_conf      :: TCKRConf,

        db_block      :: Database Hash256 (Height, Block),
        db_chain      :: Database Height Hash256,
        db_global     :: Database String DBAny,
        -- global var
        -- 1. "height" :: Height, height >= real height

        orphan_pool   :: OSET.OSet Block,
        buffer_chain  :: Maybe Branch,
        -- replace the old buffer chain when a new buffer chain is formed
        -- the length of the buffer chain should >= tckr_max_tree_insert_depth
        edge_branches :: [Branch]
    }

initChain :: TCKRConf -> ResIO Chain
initChain conf@(TCKRConf {
    tckr_db_path = db_path,
    tckr_ks_block = ks_block,
    tckr_ks_chain = ks_chain,
    tckr_ks_global = ks_global,

    tckr_genesis_raw = genesis_raw,
    tckr_max_tree_insert_depth = max_depth
}) = do
    db_block <- openDB def db_path ks_block
    db_chain <- openDB def db_path ks_chain
    db_global <- openDB def db_path ks_global

    let chain = Chain {
            std_conf = conf,
            db_block = db_block,
            db_chain = db_chain,
            db_global = db_global,

            orphan_pool = OSET.empty,
            
            buffer_chain = Nothing,
            edge_branches = []
        }

    mheight <- lift $ get db_global "height"

    case mheight :: Maybe Height of
        Nothing ->
            -- empty chain
            -- load genesis to the memory
            return $ case decodeLE genesis_raw of
                (Left err, _) -> error $ "genesis decode error: " ++ show err

                (Right genesis, _) -> do
                    chain {
                        edge_branches = [BlockNode {
                            prev_node = Nothing,
                            block_data = genesis,

                            acc_diff = targetBDiff (hash_target genesis),
                            cur_height = 0
                        }]
                    }
        
        Just height -> lift $ do
            -- load at least tckr_max_tree_insert_depth blocks into the edge_branches
            let min_height =
                    if height > fi max_depth then
                        height - fi max_depth
                    else 0
                
                range =
                    if height > 0 then [ height, height - 1 .. min_height ]
                    else [0]

            hashes <- maybeCat <$> mapM (get db_chain) range
                   :: IO [Hash256]

            res    <- maybeCat <$> mapM (get db_block) hashes
                   :: IO [(Height, Block)]
            
            let fold_proc (height, block) Nothing =
                    Just $ BlockNode {
                        prev_node = Nothing,
                        block_data = block,
                        acc_diff = targetBDiff (hash_target block),
                        cur_height = height
                    }

                fold_proc (height, block) (Just node) =
                    Just $ BlockNode {
                        prev_node = Just node,
                        block_data = block,
                        acc_diff = targetBDiff (hash_target block) + acc_diff node,
                        cur_height = height
                    }

            -- print height

            return $ case foldr fold_proc Nothing res of
                Nothing -> error "corrupted database(height field not correct for db_global)"
                Just branch ->
                    chain {
                        edge_branches = [branch]
                    }


-- load db from path
-- set orphan pool to Nothing
-- load at least tckr_max_tree_insert_depth blocks into the edge_branches
-- 

{-

what do we need to check with a block

1. duplication
2. non-empty transaction list
3. block hash satisfy diff_bits
4. timestamp < 2 hours in the future
5. first transaction is coinbase
6. partial transaction check (x)
7. total sig_script op count < MAX_BLOCK_SIGOPS
8. check merkle hash

if orphan then
    put into the orphan pool, query peer, done
else
    1. check diff_bits match the difficulty rules
    2. timestamp > median time of last 11 blocks
    3. check old block hash (x)

    if block in main branch then
        1. for all transaction besides coinbase:
            1. all input exists
            2. if input is coinbase, it must have COINBASE_MATURITY confirmations(depth of the block)
            3. inputs are unspent(in the main branch)
            4. sum of output <= sum of input
        2. delete duplicate transactions from the transaction pool
        3. relay
    else if block in side branch then
        if side branch <= main branch then
            add to the branch and do nothing
        else
            1. do the same check for all blocks from the fork point
            2. if reject, keep the original main branch

            3. put all valid transactions in side branch to the tx pool
            4. delete duplicate transactions from the transaction pool
            5. relay

9. try to connect orphan blocks to this new block if not rejected(from step 1)

-}

-- search edge branches, if found, insert to the branch
-- else search chain, if found, check if it's too deep, abandon the block
-- if not too deep, load the required range of block into the edge

-- in ascending order of height
branchToBlockList' :: [(Height, Block)] -> Maybe Branch -> [(Height, Block)]
branchToBlockList' cur Nothing = cur
branchToBlockList' cur (Just (BlockNode {
    cur_height = height,
    block_data = block,
    prev_node = mprev
})) = branchToBlockList' ((height, block) : cur) mprev

branchToBlockList = branchToBlockList' [] . Just

-- search and return a block node
searchBranch :: Branch -> (Branch -> Bool) -> Maybe Branch
searchBranch node@(BlockNode {
    prev_node = prev
}) pred =
    if pred node then Just node
    else prev >>= (`searchBranch` pred)

searchBranchHash node hash =
    searchBranch node ((== hash) . block_hash . block_data)

searchBranchHeight node height =
    searchBranch node ((== height) . cur_height)

insertToEdge :: Chain -> Block -> Maybe (Branch, Chain)
insertToEdge chain@(Chain {
    buffer_chain = buffer_chain,
    edge_branches = edge_branches
}) block@(Block {
    hash_target = hash_target,
    prev_hash = prev_hash
}) = do
    let search_res =
            [ b | Just b <- map (`searchBranchHash` prev_hash) edge_branches ]

    prev_bn <-
        if null search_res then
            case buffer_chain of
                Just bufc -> searchBranchHash bufc prev_hash
                Nothing -> Nothing
        else
            Just $ head search_res
    -- if nothing is found in edge branches and the buffer chain
    -- Nothing is returned here

    let new_node =
            BlockNode {
                prev_node = Just prev_bn,
                block_data = block,

                cur_height = cur_height prev_bn + 1,
                acc_diff = acc_diff prev_bn + targetBDiff hash_target
            }

    -- previous block found, inserting to the tree
    return $ (,) new_node $ case elemIndex prev_bn edge_branches of
        Just leaf_idx ->
            -- previous block is a leaf
            chain {
                edge_branches = replace leaf_idx new_node edge_branches
            }

        Nothing ->
            chain {
                edge_branches = new_node : edge_branches
            }

blocksAtHeight :: Chain -> Height -> IO [Block]
blocksAtHeight chain height =
    (maybeCat <$>) $ forM (edge_branches chain) $
        \b -> blockAtHeight chain b height

blockAtHeight :: Chain -> Branch -> Height -> IO (Maybe Block)
blockAtHeight (Chain {
    db_chain = db_chain,
    db_block = db_block,
    buffer_chain = buffer_chain
}) branch@(BlockNode {
    cur_height = max_height
}) height =
    if height > max_height then
        return Nothing
    else do
        let search branch = 
                searchBranchHeight branch height >>=
                (return . block_data)

        case search branch <|> (buffer_chain >>= search) of
            Just block ->
                return $ Just block

            Nothing -> do
                -- not found in branch or buf_chain
                -- search db
                res <- get db_chain height :: IO (Maybe Hash256)

                case res of
                    Nothing -> return Nothing
                    Just hash -> do
                        Just (_, block) <- get db_block hash
                                        :: IO  (Maybe (Height, Block))
                        return $ Just block

hashTargetValid :: Chain -> Branch -> IO Bool
hashTargetValid chain@(Chain {
    std_conf = conf
}) branch@(BlockNode {
    cur_height = height,
    block_data = Block {
        hash_target = hash_target
    }
}) = do
    let change_cond = shouldDiffChange conf height

    mprev_1_block <- blockAtHeight chain branch (height - 1)
    mprev_2016_block <- blockAtHeight chain branch (height - 2016)

    let expect_target =
            if tckr_use_special_min_diff conf then
                -- TODO: non-standard special-min-diff
                return $ fi tucker_bdiff_diff1
            else do
                Block { hash_target = old_target, timestamp = t2 } <- mprev_1_block

                if not change_cond then
                    return old_target
                else do
                    Block { timestamp = t1 } <- mprev_2016_block
                    
                    let actual_span = fi $ t2 - t1
                        expect_span = fi $ tckr_expect_diff_change_time conf

                        -- cal_span is in [ exp * 4, exp / 4 ]
                        -- to avoid rapid increase in difficulty
                        cal_span =
                            if actual_span > expect_span * 4 then
                                expect_span * 4
                            else if actual_span < expect_span `div` 4 then
                                expect_span `div` 4
                            else
                                actual_span
                    
                        new_target = old_target * cal_span `div` expect_span

                        real_target = unpackHash256 (packHash256 new_target)

                    return real_target

    return $ case (>= hash_target) <$> expect_target of
        Nothing -> False
        Just res -> res

    where
        shouldDiffChange conf height =
            height /= 0 &&
            height `mod` fi (tckr_diff_change_span conf) == 0

-- difference between the max and the second max value
minTopDiff :: Real t => [t] -> t
minTopDiff lst =
    let
        (max1, i) = maximum $ zip lst [0..]
        remain = take i lst ++ drop (i + 1) lst
        max2 = maximum remain
    in
        if null remain then max1
        else max2 - max1

saveBranch :: Chain -> Branch -> IO ()
saveBranch (Chain {
    db_chain = db_chain,
    db_global = db_global
}) branch = do
    -- ascending order of height
    let pairs = branchToBlockList branch

    if not (null pairs) then do
        -- save height later to ensure the height <= real height
        let (height, _) = last pairs
        mheight <- get db_global "height"

        case mheight of
            Nothing ->
                set db_global "height" height

            Just cur_height -> do
                if height > cur_height then
                    -- save height first
                    set db_global "height" height
                else
                    return ()
        
        forM pairs $ \(height, (Block { block_hash = hash })) ->
            set db_chain height hash

        return ()
    else
        return ()

-- try to fix a highest branch to save some memory
fixBranch :: Chain -> IO Chain
fixBranch chain@(Chain {
    std_conf = conf,
    buffer_chain = buffer_chain,
    edge_branches = branches
}) = do
    let depth =
            if length branches > 1 then
                minTopDiff $ map cur_height branches
            else if not (null branches) then
                fi $ length (branchToBlockList (head branches))
            else 0

        winner@(BlockNode {
            prev_node = mprev
        }) = maximum branches

    -- print depth

    if fi depth > tckr_max_tree_insert_depth conf then
        case mprev of
            -- only one node in the branch -> keep the original chain
            Nothing -> return chain

            -- remove loser branches and replace the buffer chain
            Just prev -> do
                -- write old buffer_chain to db_chain
                case buffer_chain of
                    Nothing -> return ()
                    Just bufc -> saveBranch chain bufc

                return $ chain {
                    buffer_chain = Just prev,
                    edge_branches = [winner {
                        prev_node = Nothing
                    }]
                }

    else return chain

-- should not fail
collectOrphan :: Chain -> IO Chain
collectOrphan chain@(Chain {
    orphan_pool = orphan_pool
}) = do
    let orphan_list = OSET.toAscList orphan_pool
        fold_proc (suc, chain) block = do
            -- print "hi"
            mres <- addBlock chain block
            return $ case mres of
                Right new_chain -> (True, new_chain)
                Left _ -> (suc, chain) -- don't throw

    (suc, chain) <- foldM fold_proc (False, chain) orphan_list

    if suc then collectOrphan chain -- if success, try to collect the orphan again
    else return chain -- otherwise return the original chain

addBlock :: Chain -> Block -> IO (Either TCKRError Chain)
addBlock chain block = ioToEitherIO (addBlockFail chain block)

-- throws a TCKRError when rejecting the block
addBlockFail :: Chain -> Block -> IO Chain
addBlockFail chain@(Chain {
    std_conf = conf,
    db_block = db_block,
    orphan_pool = orphan_pool
}) block@(Block {
    block_hash = block_hash,
    hash_target = hash_target,
    timestamp = timestamp,
    merkle_root = merkle_root,
    txns = txns
}) = do
    expectFalseIO "block already exists" $
        chain `hasBlockInChain` block

    -- don't check if the block is in orphan or not

    expectTrue "empty tx list" $
        not (null txns)

    expectTrue "hash target not met" $
        hash_target > block_hash

    cur_time <- unixTimestamp

    expectTrue "timestamp too large" $
        timestamp <= cur_time + tckr_max_block_future_diff conf

    expectTrue "first transaction is not coinbase" $
        isCoinbase (head txns)

    -- TODO:
    -- for each transaction, apply "tx" checks 2-4
    -- for the coinbase (first) transaction, scriptSig length must be 2-100
    -- reject if sum of transaction sig opcounts > MAX_BLOCK_SIGOPS

    -- 9b0fc92260312ce[4]4e74ef369f5c66b[b]b85848f2eddd5a7[a]1cde251e54ccfdd5
    -- 9b0fc92260312ce[5]4e74ef369f5c66b[c]b85848f2eddd5a7[b]1cde251e54ccfdd5
    -- 9b0fc92260312ce44e74ef369f5c66bbb85848f2eddd5a7a1cde251e54ccfdd5

    -- 000000006a625f06636b8bb6ac7b960a8d03705d1ace08b1a19da3fdcc99ddbd
    -- 000000006a625f06636b8bb6ac7b960a8d03705d1ace08b1a19da3fdcc99ddbd

    -- print 11
    -- print (block_hash)
    -- print (merkle_root)
    -- print (merkleRoot block)
    -- print (stdHash256 $ encodeLE (head txns))
    -- print (BSR.length $ encodeLE (head txns))

    expectTrue "merkle root claimed not correct" $
        merkleRoot block == merkle_root

    case insertToEdge chain block of
        Nothing -> do -- no previous hash found
            has_recv <- db_block `has` prev_hash block
        
            -- if has_recv then
            --     -- have received the previous block
            --     -- but it's too deep to change
            --     reject "the previous block is too old to fetch"
            -- else
            --     -- put it into the orphan pool
            return $ chain {
                orphan_pool = orphan_pool OSET.|> block
            }

        Just (branch, chain) -> do
            -- block inserted, new branch leaf created

            expectTrueIO "wrong difficulty" $
                hashTargetValid chain branch

            -- TODO: reject if timestamp is the median time of the last 11 blocks or before(MTP?)
            -- TODO: further block checks
            
            -- all check passed
            -- write the block into the block database
            set db_block block_hash (cur_height branch, block)

            is_orphan <- chain `hasBlockInOrhpan` block

            final_chain <-
                if is_orphan then
                    -- remove the block from orphan pool if accepted
                    return $ chain {
                        orphan_pool = OSET.delete block orphan_pool
                    }
                else
                    -- new block added, collect orphan
                    collectOrphan chain

            fixBranch final_chain

-- received before && is in a branch
hasBlockInChain :: Chain -> Block -> IO Bool
hasBlockInChain chain@(Chain {
    db_block = db_block
}) block@(Block {
    block_hash = hash
}) = do
    mres <- get db_block hash :: IO (Maybe (Height, Block))
    case mres of
        Nothing -> return False
        Just (height, _) ->
            (not . null) <$> blocksAtHeight chain height

hasBlockInOrhpan :: Chain -> Block -> IO Bool
hasBlockInOrhpan chain block =
    return $ block `OSET.member` orphan_pool chain

-- search two places for the block: block db and the orphan pool
hasBlock :: Chain -> Block -> IO Bool
hasBlock chain block =
    (||) <$> hasBlockInChain chain block <*> hasBlockInOrhpan chain block

reject :: String -> IO a
reject msg = throw $ TCKRError msg

expect :: Eq a => String -> a -> IO a -> IO ()
expect msg exp mobs = do
    obs <- mobs
    
    if exp == obs then return ()
    else
        reject msg

expectTrueIO msg cond = expect msg True cond
expectFalseIO msg cond = expect msg False cond
expectTrue msg cond = expect msg True $ pure cond
expectFalse msg cond = expect msg False $ pure cond

merkleParents :: [Hash256] -> [Hash256]
merkleParents [] = []
merkleParents [a] =
    [ stdHash256 $ hash256ToBS a <> hash256ToBS a ]

merkleParents (l:r:leaves) =
    (stdHash256 $ hash256ToBS l <> hash256ToBS r) :
    merkleParents leaves

merkleRoot' :: [Hash256] -> [Hash256]
merkleRoot' [] = [nullHash256]
merkleRoot' [single] = [single]
merkleRoot' leaves = merkleRoot' $ merkleParents leaves

merkleRoot :: Block -> Hash256
merkleRoot (Block {
    txns = txns
}) = head $ merkleRoot' (map (stdHash256 . encodeLE) txns)

--------------------------------------------------------

-- data BlockTreePartInfo =
--     BlockTreePartInfo {
--         tree_height :: TreeHeight
--     } deriving (Show)

-- -- BlockTreePart prev_hash 
-- data BlockTreePart = BlockTreePart {
--         prev_hashes :: [Hash256], -- if prev_hashes == [], the layers starts from genesis
--         layers      :: [[Block]]
--     } deriving (Eq, Show)

-- instance Monoid BlockTreePart where
--     mempty = emptyTreePart
--     mappend a b =
--         case linkTreePart a b of
--             -- hopefully somebody will catch it
--             Nothing -> throw $ TCKRError "tree part not connectable"
--             Just c -> c

-- instance Encodable BlockTreePart where
--     encode end (BlockTreePart hashes layers) =
--         encodeVList end hashes <>
--         encodeVList end (map (encodeVList end) layers)

-- instance Decodable BlockTreePart where
--     decoder = do
--         hashes <- vlistD decoder
--         layers <- vlistD (vlistD decoder)

--         return $ BlockTreePart hashes layers

-- -- break from genesis
-- splitTreePart :: Int -> BlockTreePart -> (BlockTreePart, BlockTreePart)
-- splitTreePart n (BlockTreePart hashes layers) =
--     (BlockTreePart hashes prev,
--      BlockTreePart (lastHash prev) (next))
--     where
--         (prev, next) = splitAt n layers

--         lastHash layers =
--             if null layers then []
--             else map block_hash $ last prev

-- linkTreePart :: BlockTreePart -> BlockTreePart -> Maybe BlockTreePart
-- linkTreePart (BlockTreePart h1 l1) (BlockTreePart h2 l2) =
--     if null l1 then
--         Just $ BlockTreePart h2 l2
--     else if null l2 then
--         Just $ BlockTreePart h1 l1
--     else if sort h2 == sort last_l1_hash then
--         -- check if hash matches
--         Just $ BlockTreePart h1 (l1 ++ l2)
--     else
--         Nothing
--     where
--         last_l1_hash = map block_hash $ last l1

-- emptyTreePart = BlockTreePart [] []

-- treePartHeight :: BlockTreePart -> TreeHeight
-- treePartHeight (BlockTreePart { layers = layers }) = fromIntegral $ length layers

-- treePartInfo :: BlockTreePart -> BlockTreePartInfo
-- treePartInfo part =
--     BlockTreePartInfo {
--         tree_height = treePartHeight part
--     }

-- treePartLatestHash :: BlockTreePart -> [Hash256]
-- treePartLatestHash (BlockTreePart prev_hashes layers) =
--     if null layers then prev_hashes
--     else map (block_hash) $ last layers
