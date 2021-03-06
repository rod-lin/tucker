module Tucker.Wallet.Wallet where

import Data.Word
import qualified Data.ByteString as BSR
import qualified Data.ByteString.Char8 as BS

import Control.Monad
import Control.Exception
import Control.Monad.Morph
import Control.Monad.Trans.Resource

import System.Directory

import Tucker.DB
import Tucker.ECC
import Tucker.Enc
import Tucker.Msg
import Tucker.Conf
import Tucker.Util
import Tucker.Atom
import Tucker.Error
import Tucker.Crypto

import Tucker.Container.IOMap
import qualified Tucker.Container.Map as MAP

import Tucker.Wallet.HD
import Tucker.Wallet.Address
import Tucker.Wallet.Mnemonic
import Tucker.Wallet.TxBuilder

-- import Tucker.State.Tx

{-

[
    ([OP_PUSHDATA "\ETXh:\241\186WC\189\252y\140\248\DC4\239\238\171'5\236R\217^\206\213(\230\146\184\227LNVi" Nothing,OP_CHECKSIG],
     RedeemSign []),
    
    ([OP_PUSHDATA "\EOTh:\241\186WC\189\252y\140\248\DC4\239\238\171'5\236R\217^\206\213(\230\146\184\227LNVi\210\242hl\237\150\211u\167R\152\240~\211\aQ\226\163\244^-\CANK&\141\STX\200\213\221o\189\181" Nothing,OP_CHECKSIG],
     RedeemSign []),
    
    ([OP_DUP,OP_HASH160,OP_PUSHDATA "A\214;P\216\221^s\f\223Ly\165o\201)\167W\197H" Nothing,OP_EQUALVERIFY,OP_CHECKSIG],
     RedeemSign [OP_PUSHDATA "\ETXh:\241\186WC\189\252y\140\248\DC4\239\238\171'5\236R\217^\206\213(\230\146\184\227LNVi" Nothing]),
    
    ([OP_DUP,OP_HASH160,OP_PUSHDATA "\230*E\238^\224\154\222\164\v\r\GS\210\rp\221<\148\209\156" Nothing,OP_EQUALVERIFY,OP_CHECKSIG],
     RedeemSign [OP_PUSHDATA "\EOTh:\241\186WC\189\252y\140\248\DC4\239\238\171'5\236R\217^\206\213(\230\146\184\227LNVi\210\242hl\237\150\211u\167R\152\240~\211\aQ\226\163\244^-\CANK&\141\STX\200\213\221o\189\181" Nothing]),
    
    ([OP_HASH160,OP_PUSHDATA "\247|\226\196,\175\138\202\244\223\149u4\190\145q\206/\175\252" Nothing,OP_EQUAL],
     RedeemSign [OP_PUSHDATA "!\ETXh:\241\186WC\189\252y\140\248\DC4\239\238\171'5\236R\217^\206\213(\230\146\184\227LNVi\172" Nothing]),
     
    ([OP_HASH160,OP_PUSHDATA "m\254cEE;c\249\&0 VjA\189\129\244\188f\128\191" Nothing,OP_EQUAL],
     RedeemSign [OP_PUSHDATA "A\EOTh:\241\186WC\189\252y\140\248\DC4\239\238\171'5\236R\217^\206\213(\230\146\184\227LNVi\210\242hl\237\150\211u\167R\152\240~\211\aQ\226\163\244^-\CANK&\141\STX\200\213\221o\189\181\172" Nothing]),
     
    ([OP_HASH160,OP_PUSHDATA "7\FS\255\SO\190\210g#\179\169\SI\184\130\233\226\131\153\187\203\253" Nothing,OP_EQUAL],
     RedeemSign [OP_PUSHDATA "\ETXh:\241\186WC\189\252y\140\248\DC4\239\238\171'5\236R\217^\206\213(\230\146\184\227LNVi" Nothing,OP_PUSHDATA "v\169\DC4A\214;P\216\221^s\f\223Ly\165o\201)\167W\197H\136\172" Nothing]),
     
    ([OP_HASH160,OP_PUSHDATA "\DC2\162\195\&1{\SOH\139s\147\223\245-\t\223Z:k\221/\213" Nothing,OP_EQUAL],
     RedeemSign [OP_PUSHDATA "\EOTh:\241\186WC\189\252y\140\248\DC4\239\238\171'5\236R\217^\206\213(\230\146\184\227LNVi\210\242hl\237\150\211u\167R\152\240~\211\aQ\226\163\244^-\CANK&\141\STX\200\213\221o\189\181" Nothing,OP_PUSHDATA "v\169\DC4\230*E\238^\224\154\222\164\v\r\GS\210\rp\221<\148\209\156\136\172" Nothing])
]

-}

-- shows how to redeem a specific outpoint
data RedeemScheme
    = RedeemScript [ScriptOp]
    | RedeemWitness [ScriptOp] TxWitness
    | RedeemSign ECCPrivateKey [ScriptOp]
    deriving (Show)

data RedeemOutPoint =
    RedeemOutPoint {
        rd_prev_out :: OutPoint,
        rd_output   :: TxOutput,
        rd_scheme   :: RedeemScheme
    }

instance TxInputBuilder RedeemOutPoint where
    toDraftInput conf (RedeemOutPoint prev_out _ (RedeemScript script)) =
        return (TxInput {
            prev_out = prev_out,
            sig_script = encodeLE script,
            seqn = maxBound
        }, nullWitness)

    toDraftInput conf (RedeemOutPoint prev_out _ (RedeemWitness script wit)) =
        return (TxInput {
            prev_out = prev_out,
            sig_script = encodeLE script,
            seqn = maxBound
        }, wit)

    toDraftInput conf (RedeemOutPoint prev_out _ (RedeemSign _ script)) =
        return (TxInput {
            prev_out = prev_out,
            sig_script = BSR.empty,
            seqn = maxBound
        }, nullWitness)

    toFinalInput conf tx in_idx (RedeemOutPoint prev_out output (RedeemSign priv script)) = do
        let htype = HashType [SIGHASH_ALL]
            hash = txSigHashLegacy tx in_idx (decodeFailLE (pk_script output)) htype

        sig <- sign priv hash
         
        return (TxInput {
            prev_out = prev_out,
            sig_script = encodeLE $ [
                    OP_PUSHDATA (encodeAE sig <> encodeBE (hashTypeToInt htype :: Word8)) Nothing
                ] ++ script,
            seqn = maxBound
        }, nullWitness)

    toFinalInput conf _ _ r = toDraftInput conf r

instance Encodable RedeemScheme where
    encode _ (RedeemScript script) =
        encodeLE (0 :: Word8) <> encodeLE script

    encode _ (RedeemWitness script wit) =
        encodeLE (1 :: Word8) <> encodeLE wit <> encodeLE script

    encode _ (RedeemSign priv append) =
        encodeLE (2 :: Word8) <> encodeAE priv <> encodeLE append

instance Decodable RedeemScheme where
    decoder = do
        head <- decoder :: Decoder Word8

        case head of
            0 -> RedeemScript <$> decoder
            1 -> do
                wit <- decoder
                script <- decoder
                return (RedeemWitness script wit)

            2 -> RedeemSign <$> decoder <*> decoder

            _ -> fail "illegal redeem scheme format"

data AddressInfo
    = AddressInfo ECCPrivateKey
    | WatchOnly -- don't have the private key
    deriving (Eq, Show)

data AddressMemInfo =
    AddressMemInfo {
        addr_balance :: Satoshi,
        addr_utxo    :: UTXOBucket
    }

instance Encodable AddressInfo where
    encode _ (AddressInfo priv) = encodeLE True <> encodeAE priv
    encode _ WatchOnly = encodeLE False <> mempty

instance Decodable AddressInfo where
    decoder = do
        is_mine <- decoder

        if is_mine then AddressInfo <$> decoder
        else return WatchOnly

type UTXOBucket = DBBucket OutPoint TxOutput

data Wallet =
    Wallet {
        wal_conf          :: TCKRConf,

        wal_db            :: Database,

        wal_bucket_conf   :: DBBucket String Placeholder,
        wal_bucket_addr   :: DBBucket String AddressInfo,

        wal_addr_utxo     :: AtomMap String AddressMemInfo,

        wal_bucket_redeem :: DBBucket ByteString RedeemScheme
    }

type PrimaryAddress = ByteString -- hash160 of the compressed public key

unknown_address = "unknown"

initWallet :: TCKRConf -> ResIO Wallet
initWallet conf@(TCKRConf {
    tckr_wallet_path = path,
    tckr_wallet_db_max_file = db_max_file,

    tckr_wallet_bucket_conf_name = conf_name,
    tckr_wallet_bucket_addr_name = addr_name,
    tckr_wallet_bucket_utxo_name = utxo_name,
    tckr_wallet_bucket_redeem_name = redeem_name
}) = do
    exist <- lift $ doesPathExist path

    assertMT "wallet does not exist" exist

    db <- openDB (optMaxFile db_max_file def) path

    bucket_conf <- lift $ openBucket db conf_name
    bucket_addr <- lift $ openBucket db addr_name
    bucket_redeem <- lift $ openBucket db redeem_name

    unknown_utxo <- lift $ openBucket db utxo_name

    let countUTXO addr utxo = do
            values <- mapKeyIO utxo $ \k -> do
                Just out <- lookupIO utxo k
                return (value out)

            return (addr, AddressMemInfo {
                addr_balance = sum values,
                addr_utxo = utxo
            })

    alist <- lift $ mapKeyIO bucket_addr $ \addr ->
        openBucket db (utxo_name ++ "." ++ addr) >>=
        countUTXO addr

    unknown_info <- lift $ countUTXO unknown_address unknown_utxo

    addr_utxo <- lift $ newA (MAP.fromList (unknown_info : alist))

    return Wallet {
        wal_conf = conf,
        wal_db = db,
        wal_bucket_conf = bucket_conf,
        wal_bucket_addr = bucket_addr,
        wal_addr_utxo = addr_utxo,
        wal_bucket_redeem = bucket_redeem
    }

-- create a new wallet from mnemonic words
newWalletFromMnemonic :: TCKRConf -> [String] -> Maybe String -> IO ()
newWalletFromMnemonic conf words mpass =
    case mnemonicToSeed def words mpass of
        Right seed -> newWalletFromSeed conf seed
        Left err -> throw err

allPossiblePayments :: TCKRConf -> ECCPrivateKey -> [([ScriptOp], RedeemScheme)]
allPossiblePayments conf priv =
    let pub = privToPub priv

        pubs = [
                encodeLE (compress pub),
                encodeLE (uncompress pub)
            ]

        hash160 = ripemd160 . sha256

        -- pub_hashes = hash160 <$> pubs

        p2pk = for pubs $ \pub ->
            ([ OP_PUSHDATA pub Nothing, OP_CHECKSIG ], RedeemSign priv [])

        p2pkh = for pubs $ \pub ->
            ([ OP_DUP, OP_HASH160, OP_PUSHDATA (hash160 pub) Nothing, OP_EQUALVERIFY, OP_CHECKSIG ],
             RedeemSign priv [ OP_PUSHDATA pub Nothing ])

        p2sh = for (p2pk ++ p2pkh) $ \(script, RedeemSign priv append) ->
            ([ OP_HASH160, OP_PUSHDATA (hash160 (encodeLE script)) Nothing, OP_EQUAL ],
             RedeemSign priv (append ++ [ OP_PUSHDATA (encodeLE script) Nothing ]))

    in p2pk ++ p2pkh ++ p2sh

newWalletFromSeed :: TCKRConf -> ByteString -> IO ()
newWalletFromSeed conf@(TCKRConf {
    tckr_wallet_path = path,
    tckr_wallet_bucket_addr_name = addr_name,
    tckr_wallet_bucket_redeem_name = redeem_name
}) seed = do
    let path = tckr_wallet_path conf
    
    exist <- doesPathExist path

    assertMT "path already exists(maybe an old wallet is there)" (not exist)

    let key = either throw id (seedToMaskerKey conf seed)

    withDB def path $ \db -> do
        bucket_addr <- openBucket db addr_name
        bucket_redeem <- openBucket db redeem_name

        let priv = toECCPrivateKey key

            -- generate all possible patterns and their respective redeem schemes
            -- p2pk
            -- p2pkh
            -- p2sh - p2pkh
            -- p2sh - p2pk
            -- leave the witness versions for now
            -- p2wpkh
            -- p2sh - p2wpkh
            payments = allPossiblePayments conf priv

            addrs =
                unique $
                maybeCat $
                map (pubKeyScriptToAddress . fst) payments
         
        forM_ payments $ \(pk_script, redeem) ->
            insertIO bucket_redeem (sha256 (encodeLE pk_script)) redeem

        -- store all possible addresses
        forM_ addrs $ \addr ->
            insertIO bucket_addr (encodeAddress conf addr) (AddressInfo priv)

isMine :: Wallet -> TxOutput -> IO Bool
isMine wallet output =
    isJust <$> lookupIO (wal_bucket_redeem wallet) hash
    where hash = sha256 (pk_script output)

eachAddress :: Wallet -> (String -> AddressMemInfo -> IO a) -> IO ()
eachAddress wallet proc =
    getA (wal_addr_utxo wallet) >>=
    (mapM_ (uncurry proc) . MAP.toList)

updateAddressInfo :: Wallet -> String -> (AddressMemInfo -> IO AddressMemInfo) -> IO ()
updateAddressInfo wallet addr proc = do
    minfo <- lookupIO (wal_addr_utxo wallet) addr

    case minfo of
        Nothing -> error ("unrecognized address " ++ addr)
        Just info ->
            proc info >>=
            insertIO (wal_addr_utxo wallet) addr

removeAddressOutPoint :: OutPoint -> AddressMemInfo -> IO AddressMemInfo
removeAddressOutPoint outpoint info = do
    mout <- lookupIO (addr_utxo info) outpoint

    case mout of
        Nothing -> return info
        Just out -> do
            deleteIO (addr_utxo info) outpoint
            return info {
                addr_balance = addr_balance info - value out
            }

addAddressOutPoint :: OutPoint -> TxOutput -> AddressMemInfo -> IO AddressMemInfo
addAddressOutPoint outpoint output info = do
    mout <- lookupIO (addr_utxo info) outpoint

    case mout of
        Just out -> return info
        Nothing -> do
            insertIO (addr_utxo info) outpoint output
            return info {
                addr_balance = addr_balance info + value output
            }

-- tx should not be coinbase
addTxIfMine :: Wallet -> TxPayload -> IO ()
addTxIfMine wallet tx = do
    -- remove all used outpoints
    forM_ (tx_in tx) $ \input ->
        removeOutPointIfMine wallet (prev_out input)

    -- add outpoint if isMine
    forM_ ([0..] `zip` tx_out tx) $ \(i, out) -> do
        addOutPointIfMine wallet (OutPoint (txid tx) i) out

removeTxIfMine :: Wallet -> TxPayload -> IO ()
removeTxIfMine wallet tx =
    forM_ ([0..] `zip` tx_out tx) $ \(i, _) ->
        removeOutPointIfMine wallet (OutPoint (txid tx) i)

removeOutPointIfMine :: Wallet -> OutPoint -> IO ()
removeOutPointIfMine wallet outpoint =
    eachAddress wallet $ \addr info ->
        updateAddressInfo wallet addr (removeAddressOutPoint outpoint)

addOutPointIfMine :: Wallet -> OutPoint -> TxOutput -> IO ()
addOutPointIfMine wallet outpoint output = do
    let maddr = 
            encodeAddress (wal_conf wallet) <$>
            pubKeyScriptToAddress (decodeFailLE (pk_script output))

        addr = maybe unknown_address id maddr

    is_mine <- isMine wallet output

    when is_mine $
        updateAddressInfo wallet addr (addAddressOutPoint outpoint output)

isWatchOnly :: Wallet -> String -> IO Bool
isWatchOnly wallet addr =
    (== Just WatchOnly) <$>
    lookupIO (wal_bucket_addr wallet) addr

getBalance :: Wallet -> Maybe String -> IO Satoshi
getBalance wallet maddr =
    case maddr of
        Just addr -> do
            minfo <- lookupIO (wal_addr_utxo wallet) addr

            case minfo of
                Just info -> return (addr_balance info)
                Nothing -> return 0

        Nothing -> foldValueIO (wal_addr_utxo wallet) 0 $ \sum info ->
            return (sum + addr_balance info)
