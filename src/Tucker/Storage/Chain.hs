{-# LANGUAGE DuplicateRecordFields #-}

-- block chain implementation

module Tucker.Storage.Chain where

import Data.Int -- hiding (map, findIndex, null)
import Data.Word
import qualified Data.Foldable as FD

import Control.Monad
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
import Tucker.DeepSeq

import Tucker.Storage.Tx
import Tucker.Storage.Block

data BlockChain =
    BlockChain {
        bc_conf   :: TCKRConf,
        bc_dbs    :: [Database],

        bc_chain  :: Chain,
        bc_tx_set :: TxSet
    }

instance NFData BlockChain where
    rnf (BlockChain {
        bc_chain = bc_chain,
        bc_tx_set = bc_tx_set
    }) = rnf bc_chain `seq` rnf bc_tx_set

initBlockChain :: TCKRConf -> ResIO BlockChain
initBlockChain conf@(TCKRConf {
    tckr_block_db_path = block_db_path,
    tckr_tx_db_path = tx_db_path
}) = do
    block_db <- openDB def block_db_path
    tx_db <- openDB def tx_db_path

    bc_chain <- lift $ initChain conf block_db
    bc_tx_set <- lift $ initTxSet conf tx_db

    return $ BlockChain {
        bc_conf = conf,
        bc_dbs = [ block_db, tx_db ],

        bc_chain = bc_chain,
        bc_tx_set = bc_tx_set
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

-}

latestBlocks :: BlockChain -> Int -> IO [Block]
latestBlocks chain n = topNBlocks (bc_chain chain) n

corrupt = reject "corrupted database"

calNewTarget :: TCKRConf -> Hash256 -> Word32 -> Hash256
calNewTarget conf old_target actual_span =
    -- real target used
    unpackHash256 (packHash256 new_target)
    where
        expect_span = fi $ tckr_expect_diff_change_time conf

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

shouldDiffChange :: TCKRConf -> Height -> Bool
shouldDiffChange conf height =
    height /= 0 &&
    height `mod` fi (tckr_diff_change_span conf) == 0

hashTargetValid :: BlockChain -> Branch -> IO Bool
hashTargetValid bc@(BlockChain {
    bc_conf = conf,
    bc_chain = chain
}) branch@(BlockNode {
    cur_height = height,
    block_data = Block {
        hash_target = hash_target
    }
}) = do
    -- previous block
    Just (Block {
        hash_target = old_target,
        timestamp = t2
    }) <- blockAtHeight chain branch (height - 1)

    target <-
        if tckr_use_special_min_diff conf then
            -- TODO: non-standard special-min-diff
            return $ fi tucker_bdiff_diff1
        else if shouldDiffChange conf height then do
            Just (Block { timestamp = t1 }) <-
                blockAtHeight chain branch (height - 2016)

            return $ calNewTarget conf old_target (t2 - t1)
        else
            return old_target

    return $ hash_target <= target

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
    force <$> ioToEitherIO (addBlockFail bc block)

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
    bc_tx_set = tx_set,
    bc_chain = chain
}) block@(Block {
    block_hash = block_hash,
    hash_target = hash_target,
    timestamp = timestamp,
    merkle_root = merkle_root,
    txns = txns'
}) = do
    expectTrue "require full block" $
        isFullBlock block

    let txns = FD.toList txns'

    expectFalseIO "block already exists" $
        chain `hasBlockInChain` block

    -- don't check if the block is in orphan pool

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

    expectTrue "merkle root claimed not correct" $
        merkleRoot block == merkle_root

    case insertBlock chain block of
        Nothing -> do -- no previous hash found
            traceIO "orphan block!"
            return $ bc { bc_chain = addOrphan chain block }

        Just (branch, chain) -> do
            -- block inserted, new branch leaf created

            -- update chain
            bc <- return $ bc { bc_chain = chain }

            expectTrueIO "wrong difficulty" $
                hashTargetValid bc branch

            -- TODO: reject if timestamp is the median time of the last 11 blocks or before(MTP?)
            -- TODO: further block checks

            {-
                1. input exists(the input points to a valid block and a valid index)
                2. if referenced transaction is a coinbase, make sure the depth of the input block is >= 100
                3. verify signature(involves script)
                4. referenced output is not spent
                5. validity of values involved(amount of input, amount of output, sum(inputs) >= sum(outputs))
            -}

            forM_ (zip [0..] txns) $ \(idx, tx) -> do
                let is_coinbase = isCoinbase tx

                expectTrue "more than one coinbase txns" $
                    idx == 0 || not is_coinbase

                if not is_coinbase then do
                    in_values <- forM (map prev_out (tx_in tx)) $ \outp@(OutPoint txid _) -> do
                        value <- expectMaybeIO ("outpoint not in utxo " ++ show outp) $
                            lookupUTXO tx_set outp

                        locator <- expectMaybeIO "failed to locate tx(db corrupt)" $
                            findTxId tx_set txid

                        node <- expectMaybeIO "cannot find corresponding block(db corrupt) or tx not in the current branch" $
                            blockWithHash chain branch (locatorToHash locator)

                        -- if the tx is coinbase(idx == 0), check coinbase maturity
                        expectTrue ("coinbase maturity not met for tx " ++ show txid) $
                            locatorToIdx locator /= 0 ||
                            cur_height branch - cur_height node >= fi (tckr_coinbase_maturity conf)

                        return value

                    -- validity of values
                    expectTrue "sum of inputs less than the sum of output" $
                        sum (in_values) >= getOutputValue tx
                else
                    -- omitting coinbase value check
                    return ()

                addTx tx_set block idx

            -- add tx to tx and utxo pool
            -- mapM_ (addTx tx_set block) [ 0 .. length txns - 1 ]
             
            -- all check passed
            -- write the block into the block database
            saveBlock chain branch

            if chain `hasBlockInOrphan` block then
                return $ bc { bc_chain = removeOrphan chain block }
            else do
                -- not orphan, collect other orphan
                bc <- collectOrphan bc
                chain <- tryFixBranch (bc_chain bc)
                return $ bc { bc_chain = chain }

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
}) = head $ merkleRoot' (map txid (FD.toList txns))
