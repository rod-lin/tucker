{-# LANGUAGE DuplicateRecordFields, FlexibleContexts #-}

-- block chain implementation

module Tucker.Storage.Chain where

import Data.Int -- hiding (map, findIndex, null)
import Data.Word
import Data.Bits
import qualified Data.Foldable as FD

import Control.Monad
import Control.Exception
import Control.Concurrent
import Control.Monad.Morph
import Control.Monad.Loops
import Control.Monad.Trans.Resource

import Tucker.DB
import Tucker.Msg
import Tucker.Enc
import Tucker.Util
import Tucker.Auth
import Tucker.Conf
import Tucker.Error
import Tucker.DeepSeq

import Tucker.Storage.Tx
import Tucker.Storage.Block
import Tucker.Storage.SoftFork

data BlockChain =
    BlockChain {
        bc_conf       :: TCKRConf,
        bc_dbs        :: [Database],

        bc_chain      :: Chain,
        bc_tx_state   :: TxState UTXOCache1,
        bc_fork_state :: SoftForkState
        -- use 1 layer of cache in UTXO
    }

data VerifyConf =
    VerifyConf {
        verify_enable_csv :: Bool,
        verify_cur_mtp    :: Timestamp,
        verify_cur_bnode  :: Branch,
        verify_check_dup_tx :: Bool
    }

instance NFData BlockChain where
    rnf (BlockChain {
        bc_chain = bc_chain,
        bc_tx_state = bc_tx_state
    }) = rnf bc_chain `seq` rnf bc_tx_state

initBlockChain :: TCKRConf -> ResIO BlockChain
initBlockChain conf@(TCKRConf {
    tckr_block_db_path = block_db_path,
    tckr_tx_db_path = tx_db_path
}) = do
    block_db <- openDB def block_db_path
    tx_db <- openDB def tx_db_path

    bc_chain <- lift $ initChain conf block_db
    bc_tx_state <- lift $ initTxState conf tx_db
    bc_fork_state <- lift $ initForkState conf block_db

    return $ BlockChain {
        bc_conf = conf,
        bc_dbs = [ block_db, tx_db ],

        bc_chain = bc_chain,
        bc_tx_state = bc_tx_state,
        bc_fork_state = bc_fork_state
    }

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

what do we need to check for each transaction:

1. input exists(the input points to a valid block and a valid index)
2. if referenced transaction is a coinbase, make sure the depth of the input block is >= 100
3. verify signature(involves script)
4. referenced output is not spent
5. validity of values involved(amount of input, amount of output, sum(inputs) >= sum(outputs))
6. the highest 3 bits must be 001

-}

{-

notes for BIP9

0. four states: DEFINED, STARTED, LOCKED_IN, FAILED
1. uses bits in vers(32-bits) in total to represent deployment
2. only the lowest 29 bits(2 bits restricted by BIP34, 1 other bit is used for future extension) are used
3. blocks within the same retarget period have the same state of a deployment(per 2016 blocks)
4. if 1916 blocks of the previous 2016 blocks have the version bit,
   switch the state of the next retarget period to LOCKED_IN

-}

nextInitBlock :: BlockChain -> ByteString -> Address -> IO Block
nextInitBlock bc@(BlockChain {
    bc_conf = conf,
    bc_chain = chain
}) msg addr =
    let main = mainBranch chain
        next_height = cur_height main + 1
        fee = feeAtHeight conf next_height
        coinbase = stdCoinbase conf msg addr fee

    in appendTx coinbase <$> nextEmptyBlock bc

-- next empty block on the main branch
-- NOTE that this block does not contain a coinbase
nextEmptyBlock :: BlockChain -> IO Block
nextEmptyBlock bc@(BlockChain {
    bc_conf = conf,
    bc_chain = chain
}) = do
    let main = mainBranch chain
        next_height = cur_height main + 1

    [tip] <- topNBlocks chain main 1

    target <- targetAtHeight bc main next_height
    mtp <- medianTimePast bc main next_height

    return $ updateBlockHashes $ Block {
        block_hash = undefined,
        vers = 0,
        prev_hash = block_hash tip,
        merkle_root = 0,
        btimestamp = mtp,
        hash_target =  target,
        nonce = 0,
        txns = FullList [],
        enc_cache = Nothing
    }

latestBlocks :: BlockChain -> Int -> IO [Block]
latestBlocks (BlockChain { bc_chain = chain }) n =
    fmap concat $
    forM (allBranches chain) $ \branch ->
        topNBlocks chain branch n

corrupt = reject "corrupted database"

calNewTarget :: TCKRConf -> Hash256 -> Timestamp -> Hash256
calNewTarget conf old_target actual_span =
    -- real target used
    unpackHash256 (packHash256 new_target)
    where
        expect_span = fi $ tckr_expect_retarget_time conf

        -- new_span is in [ exp * 4, exp / 4 ]
        -- to avoid rapid increase in difficulty
        new_span =
            if actual_span > expect_span * 4 then
                expect_span * 4
            else if actual_span < expect_span `div` 4 then
                expect_span `div` 4
            else
                actual_span

        new_target = old_target * (fi new_span) `div` (fi expect_span)

-- medianTimePast :: BlockChain -> Branch -> Int -> IO Timestamp
-- medianTimePast bc@(BlockChain {
--     bc_chain = chain
-- }) branch n = do
--     ts <- map btimestamp <$> (topNBlocks chain branch n)

--     return $
--         if null ts then 0
--         else median ts

-- mtp of a branch node
medianTimePastBranch bc branch = medianTimePast bc branch (cur_height branch)

-- median timestamp of n blocks before height
medianTimePast :: BlockChain -> Branch -> Height -> IO Timestamp
medianTimePast bc@(BlockChain {
    bc_conf = conf,
    bc_chain = chain
}) branch height = do
    let n = tckr_mtp_number conf

    mblocks <-
        mapM (blockAtHeight chain branch) [ height - 1, height - 2 .. height - fi n ]

    let ts = map btimestamp (maybeCat mblocks)

    return $ if null ts then 0
             else median ts

shouldRetarget :: TCKRConf -> Height -> Bool
shouldRetarget conf height =
    height /= 0 &&
    height `mod` fi (tckr_retarget_span conf) == 0

feeAtHeight :: TCKRConf -> Height -> Value
feeAtHeight conf height =
    fi (tckr_initial_fee conf) `shift`
    (fi height `div` fi (tckr_fee_half_rate conf))

updateForkDeploy :: BlockChain -> Branch -> IO ()
updateForkDeploy bc@(BlockChain {
    bc_conf = conf,
    bc_chain = chain,
    bc_fork_state = fork_state
}) branch =
    let block = block_data branch in

    if shouldRetarget conf (cur_height branch) then do
        tLnM ("retarget and update deploy status on block " ++ show block)

        -- update
        -- prev <- expectMaybeIO "no previous branch" (prevBlockNode chain branch)

        -- mtp of the parent block
        mtp <- medianTimePast bc branch (cur_height branch - 1)
        forks <- lookupNonFinalForks fork_state block

        forM_ forks $ \fork -> do
            tLnM ("update status on fork " ++ show fork)

            case fork_status fork of
                FORK_STATUS_DEFINED ->
                    if mtp > fork_timeout fork then
                        changeForkStatus fork_state fork FORK_STATUS_FAILED
                    else if mtp > fork_start fork then
                        changeForkStatus fork_state fork FORK_STATUS_STARTED
                    else do
                        tLnM "no status change"
                        return ()
                
                FORK_STATUS_STARTED ->
                    if mtp > fork_timeout fork then
                        changeForkStatus fork_state fork FORK_STATUS_FAILED
                    else do
                        -- pull out number of blocks supporting the fork
                        number <- getRecord fork_state fork
                        
                        if number > fi (tckr_soft_fork_lock_threshold conf) then
                            changeForkStatus fork_state fork FORK_STATUS_LOCKED_IN
                        else
                            return ()

                FORK_STATUS_LOCKED_IN ->
                    changeForkStatus fork_state fork FORK_STATUS_ACTIVE

                _ -> return ()

        -- clear the stat for the current retarget period
        clearRecord fork_state
        recordBlock fork_state block
    else
        recordBlock fork_state block

{-

dep_bucket DeploymentId -> [Deployment]
           id 32        -> numbers of time appeared for each bit(0-28) in the current retarget period

at first, all deployment is defined
when a block is added,
check:
if height % 2016 == 0 and the block is in the main branch then
    for all deployment declared in version:
        case deployment status of
            defined:
                if MTP > timeout then
                    set stauts to failed
                else if MTP > start then
                    set status to start
                else
                    nothing

            started:
                if MTP > timeout then
                    set stauts to failed
                else
                    check 95% threshold
                    if reached then
                        set status to locked_in
                    else
                        nothing

            locked_in:
                set status to active

            _ -> nothing
-}

-- correct target of a branch at a specific height
targetAtHeight :: BlockChain -> Branch -> Height -> IO Hash256
targetAtHeight (BlockChain {
    bc_conf = conf,
    bc_chain = chain
}) branch height = do
    -- previous block
    Just (Block {
        hash_target = old_target,
        btimestamp = t2
    }) <- blockAtHeight chain branch (height - 1)

    if tckr_use_special_min_diff conf then
        -- TODO: non-standard special-min-diff
        return $ fi tucker_bdiff_diff1
    else if shouldRetarget conf height then do
        Just (Block { btimestamp = t1 }) <-
            blockAtHeight chain branch (height - fi (tckr_retarget_span conf))

        return $ calNewTarget conf old_target (t2 - t1)
    else
        return old_target

hashTargetValid :: BlockChain -> Branch -> IO Bool
hashTargetValid bc branch@(BlockNode {
    cur_height = height,
    block_data = Block {
        hash_target = hash_target
    }
}) = (hash_target <=) <$> targetAtHeight bc branch height

-- should not fail
collectOrphan :: BlockChain -> IO BlockChain
collectOrphan bc@(BlockChain {
    bc_chain = chain
}) = do
    let orphan_list = orphanList chain
        fold_proc (suc, bc) block = do
            -- print $ "collect orphan " ++ show block
            mres <- addBlock bc block
            return $ case mres of
                Right new_bc -> (True, new_bc)
                Left _ -> (suc, bc) -- don't throw

    (suc, bc) <- foldM fold_proc (False, bc) orphan_list

    if suc then collectOrphan bc -- if success, try to collect the orphan again
    else return bc -- otherwise return the original chain

addBlock :: BlockChain -> Block -> IO (Either TCKRError BlockChain)
addBlock bc block =
    force <$> tryT (addBlockFail bc block)

addBlocks :: (Block -> Either TCKRError BlockChain -> IO ())
          -> BlockChain -> [Block]
          -> IO BlockChain
addBlocks proc bc [] = return bc
addBlocks proc bc (block:blocks) = do
    res <- addBlock bc block
    res `seq` proc block res

    let new_bc = case res of
            Left _ -> bc
            Right bc -> bc

    new_bc `seq` addBlocks proc new_bc blocks

-- test & save chain to the disk
trySyncChain :: BlockChain -> IO BlockChain
trySyncChain bc@(BlockChain {
    bc_chain = chain,
    bc_tx_state = tx_state,
    bc_fork_state = fork_state
}) = do
    mres <- tryFixBranch chain

    case mres of
        Nothing -> return bc -- no change
        Just chain -> do
            -- blockchain flushed back to disk
            -- sync utxo
            syncUTXO tx_state
            syncForkState fork_state
            
            return $ bc { bc_chain = chain }

genScriptConf :: BlockChain -> VerifyConf -> Block -> IO ScriptConf
genScriptConf bc ver_conf out_block =
    return $ def {
        script_enable_csv = verify_enable_csv ver_conf,
        script_enable_p2sh = btimestamp out_block >=
                             tckr_p2sh_enable_time (bc_conf bc)
    }

genVerifyConf :: BlockChain -> Branch -> Branch -> IO VerifyConf
genVerifyConf bc@(BlockChain {
    bc_conf = conf,
    bc_chain = bc_chain,
    bc_fork_state = fork_state
}) branch bnode = do
    csv_status <- getForkStatus fork_state "csv"
    mtp <- medianTimePast bc branch (cur_height bnode)

    return $ VerifyConf {
        verify_enable_csv = isActiveStatus csv_status,
        verify_cur_mtp = mtp,
        verify_cur_bnode = bnode,
        verify_check_dup_tx = mtp >= tckr_dup_tx_disable_time conf
    }

verifyInput :: UTXOMap a
            => BlockChain -> TxState a -> VerifyConf
            -> Branch -> TxPayload -> Int -> IO Value
verifyInput bc@(BlockChain {
    bc_conf = conf,
    bc_chain = chain,
    bc_fork_state = fork_state
}) tx_state ver_conf branch tx in_idx = do
    let inp@(TxInput {
            prev_out = outp@(OutPoint txid out_idx)
        }) = tx_in tx !! in_idx

    value <- expectMaybeIO ("outpoint not in utxo " ++ show outp) $
        lookupUTXO tx_state outp

    locator <- expectMaybeIO "failed to locate tx(db corrupt)" $
        findTxId tx_state txid

    prev_bnode <- expectMaybeIO "cannot find corresponding block(db corrupt) or tx not in the current branch" $
        branchWithHash chain branch (locatorToHash locator)

    if verify_enable_csv ver_conf &&
       version tx >= 2 then do
        error "CSV!!!"
        -- check BIP 68
        case inputLockTime inp of
            Just lock_time ->
                let v = lockTimeValue lock_time in
                case lockTimeType lock_time of
                    LOCK_TIME_HEIGHT ->
                        expectTrue "relative lock-time(block time) not met" $
                            cur_height (verify_cur_bnode ver_conf) >=
                            fi v + cur_height prev_bnode

                    LOCK_TIME_512S -> do
                        prev_time <- medianTimePastBranch bc prev_bnode
                        
                        expectTrue "relative lock-time not met" $
                            verify_cur_mtp ver_conf >= fi v * 512 + prev_time

            Nothing -> return () -- no requirement for lock time
    else
        return ()

    prev_bnode <- expectMaybeIO ("failed to load full block for " ++ show prev_bnode) $
        toFullBlockNode chain prev_bnode
        -- -- special case -> outpoint is in the current block/top
        -- if bnode == branch then return bnode
        -- else expectMaybeIO ("failed to load full block for " ++ show bnode) $
        --     toFullBlockNode chain bnode

    let prev_tx_idx = locatorToIdx locator
        prev_tx_body =
            (txns (block_data prev_bnode)) `index` fi prev_tx_idx

        prev_tx_out = tx_out prev_tx_body !! fi out_idx

    -- if the funding tx is coinbase(idx == 0), check coinbase maturity
    expectTrue ("coinbase maturity not met for outpoint tx " ++ show txid) $
        prev_tx_idx /= 0 ||
        cur_height branch - cur_height prev_bnode >= fi (tckr_coinbase_maturity conf)

    -- generate script configuration
    script_conf <- genScriptConf bc ver_conf (block_data prev_bnode)

    -- check script
    let pk_sc = decodeFailLE (pk_script prev_tx_out)
        sig_sc = decodeFailLE (sig_script inp)
        state = initState script_conf prev_tx_body tx (fi in_idx)
        check_res = runEval state [ sig_sc, pk_sc ]

    expectTrue ("invalid script/signature for outpoint tx " ++
                show txid ++ ": " ++ show check_res ++
                ": " ++ show [ sig_sc, pk_sc ]) $
        check_res == ValidTx

    -- all test passed, return value
    return value

updateChain :: BlockChain -> Chain -> IO BlockChain
updateChain bc chain =
    return $ bc {
        bc_chain = chain
    }

-- NOTE: the block given is not necessarily the tip block
verifyBlockTx :: BlockChain -> Branch -> Block -> IO ()
verifyBlockTx bc branch block = do
    let all_txns = FD.toList (txns block)
        conf = bc_conf bc

    bnode <- expectMaybeIO "the block being verified is not in the given branch" $
        branchWithHash (bc_chain bc) branch (block_hash block)

    begin_time <- msCPUTime
    ver_conf <- genVerifyConf bc branch bnode

    -- using cached utxo because any error
    -- in the tx will cause the tx state to roll back
    withCacheUTXO (bc_tx_state bc) $ \tx_state -> do
        let coinbase = head all_txns
            normal_tx = tail all_txns

        if verify_check_dup_tx ver_conf then
            forM_ (zip [0..] all_txns) $ \(idx, tx) -> do
                -- check duplicated tx
                mlocator <- findTxId tx_state (txid tx)
                
                case mlocator of
                    Nothing -> return () -- no record
                    Just locator ->
                        expectTrue ("duplicated transaction " ++ show (txid tx)) $
                            locatorToHash locator == block_hash block &&
                            locatorToIdx locator == idx
        else
            return ()

        all_fees <- forM (zip [1..] normal_tx) $ \(idx, tx) -> do
            expectTrue "more than one coinbase txns" $
                not (isCoinbase tx)

            -- tLnM $ "checking tx " ++ show idx

            let total_out_value = getOutputValue tx

            cap <- getNumCapabilities

            let len = fi (length (tx_in tx))
                idxs = [ 0 .. len - 1 ]
                sep_idxs = foldList cap idxs

                verify in_parallel in_idx = do
                    tM $ wss (Color Blue False) $
                         printf "[verifying input %d of tx %d %s%s]"
                                in_idx idx (show (txid tx))
                                (if in_parallel then "(in parallel)" else "")

                    verifyInput bc tx_state ver_conf branch tx in_idx

                verifyP = mapM (verify True) -- parallel
            -- in_values <- forM [ 0 .. len ] (verifyInput bc tx_state branch tx)

            in_values <-
                if length idxs >= tckr_min_parallel_input_check conf then do
                    -- tLnM "checking input in parallel"
                    mconcat <$>
                        map (either (reject . show) id) <$>
                        forkMapM verifyP sep_idxs
                else
                    mapM (verify False) idxs

            let fee = sum (in_values) - total_out_value
            
            -- validity of values
            expectTrue "sum of inputs less than the sum of output" $
                fee >= 0

            addTx tx_state block idx

            return fee

        -- checking coinbase

        let block_fee = feeAtHeight conf (cur_height branch)
            tx_fee = sum all_fees
            coinbase_out = getOutputValue coinbase

        expectTrue "coinbase output greater than the sum of the block creation fee and tx fees" $
            coinbase_out <= block_fee + tx_fee

        addTx tx_state block 0

    end_time <- msCPUTime :: IO Integer

    tLnM ("verified " ++ show (length all_txns) ++
          " txns in " ++ show (end_time - begin_time) ++ "ms")

-- locatorToTx :: Chain -> TxLocator -> IO (Maybe TxPayload)
-- locatorToTx (Chain {
--     bucket_block = bucket_block
-- }) locator =
--     (liftM (txns . snd) <$> getB bucket_block hash) >>=
--         (return . (>>= (!!! idx)))
--     where
--         idx = fi (locatorToIdx locator)
--         hash = locatorToHash locator

-- throws a TCKRError when rejecting the block
addBlockFail :: BlockChain -> Block -> IO BlockChain
addBlockFail bc@(BlockChain {
    bc_conf = conf,
    bc_tx_state = tx_state,
    bc_chain = chain
}) block@(Block {
    block_hash = block_hash,
    hash_target = hash_target,
    btimestamp = timestamp,
    merkle_root = merkle_root,
    txns = txns'
}) = do
    expectTrue "require full block" $
        isFullBlock block

    let all_txns = FD.toList txns'

    expectFalseIO "block already exists" $
        chain `hasBlockInChain` block

    -- don't check if the block is in orphan pool

    expectTrue "empty tx list" $
        not (null all_txns)

    expectTrue "hash target not met" $
        hash_target > block_hash

    cur_time <- unixTimestamp

    expectTrue "timestamp too large" $
        timestamp <= cur_time + tckr_max_block_future_diff conf

    expectTrue "first transaction is not coinbase" $
        isCoinbase (head all_txns)

    -- TODO:
    -- for each transaction, apply "tx" checks 2-4
    -- for the coinbase (first) transaction, scriptSig length must be 2-100
    -- reject if sum of transaction sig opcounts > MAX_BLOCK_SIGOPS

    expectTrue "merkle root claimed not correct" $
        merkleRoot block == merkle_root

    let is_orphan_block = chain `hasBlockInOrphan` block

    case insertBlock chain block of
        Nothing -> do -- no previous hash found
            -- tLnM "orphan block!"
            expectFalse "repeated orphan block" is_orphan_block
            updateChain bc (addOrphan chain block)

        Just (branch, chain) -> do
            -- block inserted, new branch leaf created

            -- update chain
            bc <- updateChain bc chain

            -- tLnM (isPartial (txns (block_data branch)))

            -- save the block data first
            -- all actions below will find the block
            -- in the chain as other normal blocks
            saveBlock chain (cur_height branch) block

            if tckr_enable_mtp_check conf then
                expectTrueIO "MTP rule not met" $
                    (btimestamp block >=) <$> medianTimePastBranch bc branch
            else
                return ()

            if tckr_enable_difficulty_check conf then
                expectTrueIO "wrong difficulty" $
                    hashTargetValid bc branch
            else
                return ()

            let main_branch = mainBranch chain

            bc <-
                if main_branch == branch then do
                    -- tLnM "adding to the main branch"
                    -- adding to the main branch
                    
                    let skip_tx_check = Just True == do
                            (height, _) <- tckr_block_assumed_valid conf
                            return (cur_height branch < fi height)

                    if not skip_tx_check then
                        verifyBlockTx bc branch block
                    else do
                        -- trust all txns
                        tLnM "txns assumed valid"
                        addTxns tx_state block

                    -- update fork deploy status
                    updateForkDeploy bc branch

                    return bc

                else if branch > main_branch then do
                    -- branch becoming the main branch
                    
                    tLnM "main branch change!!!"

                    -- set main branch
                    bc <- updateChain bc (setMainBranch chain branch)

                    -- if block check fails here, the new block will be rejected
                    -- and no update in main branch is possible
                    withCacheUTXO tx_state $ \tx_state -> do
                        let (fp1, fp2) = forkPath chain branch main_branch

                        -- [[TxPayload]]
                        -- fp1 is in descending order of heights
                        forM_ fp1 $ \bnode -> do
                            -- get full node and then get txns
                            -- to revert the UTXO

                            bnode <- toFullBlockNodeFail chain bnode

                            let all_txns = FD.toList (txns (block_data bnode))

                            -- revert the state in reverse order
                            mapM_ (revertUTXO tx_state) (reverse all_txns)
        
                        -- recheck all new main branch nodes
                        
                        -- fp2 is in descending order of heights
                        forM_ (reverse fp2) $ \bnode -> do
                            bnode <- toFullBlockNodeFail chain bnode
                            -- verify all blocks in the new main branch
                            verifyBlockTx bc branch (block_data bnode)

                    return bc
                else
                    -- still not main branch do nothing
                    return bc

            if is_orphan_block then do
                -- tLnM "orphan removed"
                updateChain bc (removeOrphan chain block)
            else do
                -- tLnM "collect orphans"
                -- not orphan, collect other orphan
                collectOrphan bc >>= trySyncChain

reject :: String -> a
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

expectMaybe msg (Just v) = return v
expectMaybe msg Nothing = reject msg

expectMaybeIO msg m = m >>= expectMaybe msg
