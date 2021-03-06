module Tucker.Conf where

import Data.Hex
import Data.Int
import Data.Word
import Data.Char
import Data.List

import qualified Data.ByteString as BSR
import qualified Data.ByteString.Char8 as BS

import System.FilePath
import System.Directory

import Network.Socket
import Crypto.PubKey.ECC.Types

tucker_curve = getCurveByName SEC_p256k1

data NodeServiceTypeSingle
    = TCKR_NODE_NETWORK
    | TCKR_NODE_GETUTXO
    | TCKR_NODE_BLOOM
    | TCKR_NODE_WITNESS deriving (Eq)

newtype NodeServiceType = NodeServiceType [NodeServiceTypeSingle] deriving (Eq)

instance Show NodeServiceTypeSingle where
    show TCKR_NODE_NETWORK = "network"
    show TCKR_NODE_GETUTXO = "getutxo"
    show TCKR_NODE_BLOOM = "bloom"
    show TCKR_NODE_WITNESS = "witness"

instance Show NodeServiceType where
    show (NodeServiceType servs) =
        intercalate ", " (map show servs)

type SoftForkId = Int32

soft_fork_id_range = [ 0 .. 28 ] :: [SoftForkId] -- only the lowest 29 bits are used(see BIP 9)

data SoftForkStatus
    = FORK_STATUS_UNDEFINED -- should not occur in the database
    | FORK_STATUS_DEFINED
    | FORK_STATUS_STARTED
    | FORK_STATUS_LOCKED_IN

    -- final status
    | FORK_STATUS_FAILED
    | FORK_STATUS_ACTIVE
    deriving (Eq, Show)

isActiveStatus :: SoftForkStatus -> Bool
isActiveStatus = (== FORK_STATUS_ACTIVE)

data SoftFork =
    SoftFork {
        fork_name    :: String,
        fork_bit     :: SoftForkId,
        fork_start   :: Timestamp,
        fork_timeout :: Timestamp,
        fork_status  :: SoftForkStatus
    } deriving (Show)

instance Eq SoftFork where
    f1 == f2 = fork_name f1 == fork_name f2 && fork_bit f1 == fork_bit f2

tucker_default_socket_hints =
    defaultHints {
        addrSocketType = Stream -- using tcp
    }

type Satoshi = Int64
type Coin = Double
type FeeRate = Satoshi -- in sat/kb
type Timestamp = Word32

feeRate :: Integral t => Satoshi -> t -> FeeRate
feeRate fee bytes = fee * 1000 `div` fromIntegral bytes

data TCKRConf =
    TCKRConf {
        tckr_net_version                :: Integer,
        tckr_node_service               :: NodeServiceType,

        -- keyspaces: block, tx, 
        tckr_block_db_path              :: FilePath,
        tckr_tx_db_path                 :: FilePath,
        tckr_bucket_block_name          :: String,
        tckr_bucket_chain_name          :: String,
        tckr_bucket_tx_name             :: String,
        tckr_bucket_utxo_name           :: String,
        tckr_bucket_fork_name           :: String,
        tckr_bucket_stat_name           :: String,

        tckr_wallet_path                :: FilePath,
        tckr_wallet_db_max_file         :: Int,
        tckr_wallet_bucket_conf_name    :: String,
        tckr_wallet_bucket_utxo_name    :: String,
        tckr_wallet_bucket_addr_name    :: String,
        tckr_wallet_bucket_redeem_name  :: String,
        tckr_enable_wallet              :: Bool,

        tckr_block_db_max_file          :: Int,
        tckr_tx_db_max_file             :: Int,
        tckr_max_socket                 :: Int,

        tckr_user_agent                 :: String,

        tckr_wif_pref                   :: Word8,
        tckr_p2pkh_addr_pref            :: Word8,
        tckr_p2sh_addr_pref             :: Word8,
        tckr_magic_no                   :: BSR.ByteString,
        tckr_hd_priv_key_prefix         :: BSR.ByteString,
        tckr_hd_pub_key_prefix          :: BSR.ByteString,
        tckr_hd_seed_key                :: String,

        tckr_listen_addr                :: String, 
        tckr_listen_port                :: Word16,

        tckr_rpc_server_addr            :: String,
        tckr_rpc_server_port            :: Word16,
        tckr_rpc_user_name              :: String,
        tckr_rpc_user_pass              :: String,

        tckr_genesis_raw                :: BSR.ByteString, -- genesis hash

        tckr_trans_timeout              :: Int, -- in sec
        tckr_bootstrap_host             :: [String],

        tckr_min_node                   :: Int,
        tckr_seek_min                   :: Int,

        tckr_max_outbound_node          :: Int,
        tckr_max_inbound_node           :: Int,

        tckr_node_blacklist             :: [SockAddr],

        tckr_speed_test_span            :: Word, -- time span of a download speed test in seconds

        tckr_gc_interval                :: Integer,

        tckr_max_block_task             :: Int,

        -- do the input checking in parrallel
        -- when nIn is greater or equal to this number
        tckr_min_parallel_input_check   :: Int,

        tckr_node_alive_span            :: Timestamp,
        tckr_reping_time                :: Timestamp,

        tckr_known_inv_count            :: Int,
        -- max number of hashes to send when trying to sync witht the network
        
        tckr_initial_fee                :: Integer,
        tckr_fee_half_rate              :: Integer,

        tckr_max_tree_insert_depth      :: Int, -- max search depth when inserting a block
        tckr_mem_only                   :: Bool, -- no write operation to the db

        tckr_fetch_dup_node             :: Int,
        -- number of duplicated nodes to fetch the same bunch of block
        tckr_fetch_dup_max_task         :: Int,
        -- if the number of block fetch task is less than this number,
        -- use dup_node

        -- max difference of the timestamp of a block with the time received
        tckr_max_block_time_future_diff :: Word32, -- in sec

        -- the difficulty changes every tckr_retarget_span blocks
        tckr_retarget_span              :: Word32,
        tckr_expect_retarget_time       :: Word32, -- expected difficulty change time in sec
        tckr_soft_fork_lock_threshold   :: Word32, -- roughly 95% of retarget span

        tckr_use_special_min_diff       :: Bool, -- support special-min-difficulty or not(mainly on testnet)
        tckr_use_special_min_diff_mine  :: Bool, -- use special-min-difficulty rule for mining
        tckr_target_spacing             :: Timestamp,

        tckr_block_fetch_timeout        :: Int, -- in sec
        tckr_node_max_blacklist_count   :: Int,

        tckr_max_getblocks_batch        :: Int,
        tckr_max_getheaders_batch       :: Int,

        tckr_sync_inv_timeout           :: Int, -- in sec
        tckr_sync_inv_node              :: Double, -- percentage of all nodes to sync from

        tckr_coinbase_maturity          :: Int,

        tckr_p2sh_enable_time           :: Timestamp,
        tckr_dup_tx_disable_time        :: Timestamp,
        tckr_mtp_number                 :: Int,

        tckr_node_max_task              :: Int,

        tckr_soft_forks                 :: [SoftFork],

        -- different from the assumevalid in bitcoin core
        -- because currently tucker does not support header-first
        -- sync and can not check whether a block is the ancestor
        -- of the assumevalid block
        tckr_block_assumed_valid        :: Maybe (Word, String),

        tckr_enable_difficulty_check    :: Bool,
        tckr_enable_mtp_check           :: Bool,

        tckr_bdiff_diff1_target         :: Integer,

        tckr_block_weight_limit         :: Int,

        tckr_job_number                 :: Int,

        tckr_pool_tx_limit              :: Int, -- when the number of pool tx reaches the limit, remove all timeout txns
        tckr_pool_tx_timeout            :: Timestamp,
        tckr_enable_mempool             :: Bool,
        tckr_min_init_mempool_size      :: Int, -- the miner will wait until this size is reached
        tckr_mempool_wait_timeout       :: Int,

        tckr_enable_miner               :: Bool,
        tckr_miner_p2pkh_addr           :: String,
        tckr_miner_msg                  :: String,

        tckr_bip34_height               :: Word, -- block height in coinbase
        tckr_bip66_height               :: Word, -- strict signature DER encoding
        tckr_bip65_height               :: Word, -- OP_CHECKLOCKTIMEVERIFY

        tckr_min_tx_fee_rate            :: FeeRate, -- in sat/kb

        tckr_reject_non_std_tx          :: Bool,
        tckr_wit_commit_header          :: BSR.ByteString
    } deriving (Show)

tucker_version = "0.0.1"

hex2bs = BS.pack . (!! 0) . unhex . map toUpper

-- tucker_cache_tree_chunk = 1

tucker_default_conf_mainnet :: Maybe FilePath -> IO TCKRConf
tucker_default_conf_mainnet mpath = do
    user_home <- getHomeDirectory

    let tucker_path = maybe (user_home </> ".tucker") id mpath

    createDirectoryIfMissing False tucker_path

    let max_file_limit = 1024

    return $ TCKRConf {
        tckr_net_version = 60002,
        tckr_node_service = NodeServiceType [ TCKR_NODE_NETWORK, TCKR_NODE_WITNESS ],

        tckr_block_db_path = tucker_path </> "db" </> "chain",
        tckr_tx_db_path = tucker_path </> "db" </> "tx",
        tckr_bucket_block_name = "block",
        tckr_bucket_chain_name = "chain",
        tckr_bucket_tx_name = "tx",
        tckr_bucket_utxo_name = "utxo",
        tckr_bucket_fork_name = "fork",
        tckr_bucket_stat_name = "stat",

        tckr_wallet_path = tucker_path </> "wallet",
        tckr_wallet_db_max_file = 64,
        tckr_wallet_bucket_conf_name = "conf",
        tckr_wallet_bucket_utxo_name = "utxo",
        tckr_wallet_bucket_addr_name = "addr",
        tckr_wallet_bucket_redeem_name = "redeem",
        tckr_enable_wallet = False,

        -- each file is roughly 2mb
        tckr_block_db_max_file = 256,
        tckr_tx_db_max_file = 256,
        tckr_max_socket = 256,

        tckr_user_agent = "/Tucker:" ++ tucker_version ++ "/",

        tckr_wif_pref = 0x80,
        tckr_p2pkh_addr_pref = 0x00,
        tckr_p2sh_addr_pref = 0x05,
        tckr_magic_no = BSR.pack [ 0xf9, 0xbe, 0xb4, 0xd9 ],
        tckr_hd_priv_key_prefix = BSR.pack [ 0x04, 0x88, 0xad, 0xe4 ],
        tckr_hd_pub_key_prefix = BSR.pack [ 0x04, 0x88, 0xb2, 0x1e ],
        tckr_hd_seed_key = "Bitcoin seed",

        tckr_listen_addr = "127.0.0.1",
        tckr_listen_port = 8333,

        tckr_rpc_server_addr = "127.0.0.1", -- only open up to local connections
        tckr_rpc_server_port = 3150,
        tckr_rpc_user_name = "tucker",
        tckr_rpc_user_pass = "sonia",

        tckr_genesis_raw = hex2bs "0100000000000000000000000000000000000000000000000000000000000000000000003BA3EDFD7A7B12B27AC72C3E67768F617FC81BC3888A51323A9FB8AA4B1E5E4A29AB5F49FFFF001D1DAC2B7C0101000000010000000000000000000000000000000000000000000000000000000000000000FFFFFFFF4D04FFFF001D0104455468652054696D65732030332F4A616E2F32303039204368616E63656C6C6F72206F6E206272696E6B206F66207365636F6E64206261696C6F757420666F722062616E6B73FFFFFFFF0100F2052A01000000434104678AFDB0FE5548271967F1A67130B7105CD6A828E03909A67962E0EA1F61DEB649F6BC3F4CEF38C4F35504E51EC112DE5C384DF7BA0B8D578A4C702B6BF11D5FAC00000000",

        tckr_trans_timeout = 5, -- sec
        tckr_bootstrap_host = [ "seed.btc.petertodd.org" ],

        tckr_min_node = 8, -- minimum number of nodes to function
        tckr_seek_min = 16, -- if node_count < min_seek then seek for more nodes
        
        tckr_max_outbound_node = 32,
        tckr_max_inbound_node = 32,
        
        tckr_node_blacklist = [
                ip4 (127, 0, 0, 1),
                ip4 (0, 0, 0, 0)
            ],
    
        tckr_speed_test_span = 5,

        tckr_gc_interval = 30 * 1000, -- 20 sec
        
        tckr_max_block_task = 20,
        tckr_min_parallel_input_check = 128, -- maxBound,

        -- in sec
        tckr_node_alive_span = 90 * 60, -- 90 min
        tckr_reping_time = 30, -- 30sec

        tckr_known_inv_count = 8,

        tckr_max_tree_insert_depth = 64,
        tckr_mem_only = False,

        tckr_max_getblocks_batch = 500,
        tckr_max_getheaders_batch = 2000,
        -- receive 500 blocks a time(if inv is greater than that, trim the tail)

        tckr_node_max_task = 3, -- excluding the base handler

        tckr_fetch_dup_node = 8,
        tckr_fetch_dup_max_task = 4,

        tckr_max_block_time_future_diff = 60 * 60 * 2, -- 2 hours

        tckr_retarget_span = 2016,
        tckr_expect_retarget_time = 14 * 24 * 60 * 60, -- 2 weeks in sec
        tckr_soft_fork_lock_threshold = 1916,

        tckr_use_special_min_diff = False,
        tckr_use_special_min_diff_mine = False,
        tckr_target_spacing = 10 * 60, -- 10 min
        -- tckr_special_min_timeout = 20 * 60, -- 20 min

        tckr_block_fetch_timeout = 10,

        tckr_node_max_blacklist_count = 5,

        tckr_sync_inv_timeout = 3,
        tckr_sync_inv_node = 0.5,

        tckr_coinbase_maturity = 100,

        tckr_p2sh_enable_time = 1333238400,
        tckr_dup_tx_disable_time = 1331769600,

        tckr_mtp_number = 11,

        tckr_initial_fee = 50 * 100000000,
        tckr_fee_half_rate = 210000,

        tckr_soft_forks = [
            SoftFork {
                fork_name = "csv",
                fork_bit = 0,
                fork_start = 1462032000,
                fork_timeout = 1493568000,
                fork_status = FORK_STATUS_DEFINED
            },
            
            SoftFork {
                fork_name = "segwit",
                fork_bit = 1,
                fork_start = 1479139200,
                fork_timeout = 1510675200,
                fork_status = FORK_STATUS_DEFINED
            }
        ],

        tckr_block_assumed_valid = Nothing,

        tckr_enable_difficulty_check = True,
        tckr_enable_mtp_check = True,

        tckr_bdiff_diff1_target = 0x00000000ffff0000000000000000000000000000000000000000000000000000,

        tckr_block_weight_limit = 4000000,

        tckr_job_number = 1,

        tckr_pool_tx_limit = 512,
        tckr_pool_tx_timeout = 7 * 60 * 60, -- 7 hours
        tckr_enable_mempool = True,
        tckr_min_init_mempool_size = 50,
        tckr_mempool_wait_timeout = 20000, -- 20 sec

        tckr_enable_miner = True,
        tckr_miner_p2pkh_addr = "mu2XoBFnT4RGqbLsFLoRuBHCqrXjbPkwBm",
        tckr_miner_msg = "github.com/rod-lin/tucker",

        -- mined blocks
        -- 00000000ac3198db46ed45f5f7f775d403122a3f16f8d89c935c50e2fea82c6b
        -- 000000008a326409067d71f3e400442facb9bbd77ebce22cd669cdeeaa3d9969
        -- 00000000e8355a816f7761cb0eede842659557e65447e3bbe4682b1dbd87ae52
        -- 000000002413a1b5ec4a700f8bff9c96084afac1a09d2799187025932a051676
        -- 000000000eaf8961c33826e446d41c188b96205d9cfd510e2e3699471194f886
        -- 000000000309b54a06091399b91efeb711d493388d6d0383fb648822ebe93ab0
        -- 00000000139462face7d944066b698d0ac5373979cfa096945bfcbc17736dbd0
        -- 0000000022e141e619155c2cc86c6e919a27505079b661ba8fd886bb3490165e
        -- 000000000a8edd5dd2998eddc6945fcfd96b1b12b65f685ded4445c8e6e29bee
        -- 000000007460ba87018897e61f14faf0d5f880b8d8f196b46a394928ea5f5a46
        -- 0000000083e25078b2951c592a86e2e72cf02c938c8b09ec31a07f19ba579ace
        -- 0000000007fc8158654cd9d62c659dfcb05adf28bf9d10c861cfb300dd23406d

        tckr_bip34_height = 227931,
        tckr_bip66_height = 363725,
        tckr_bip65_height = 388381,

        tckr_min_tx_fee_rate = 10,

        tckr_reject_non_std_tx = True,
        tckr_wit_commit_header = BSR.pack [ 0xaa, 0x21, 0xa9, 0xed ]
    }

    where
        ip4 = SockAddrInet 0 . tupleToHostAddress

tucker_default_conf_testnet3 mpath = do
    conf <- tucker_default_conf_mainnet mpath
    return $ conf {
        tckr_wif_pref = 0xef,
        tckr_p2pkh_addr_pref = 0x6f,
        tckr_p2sh_addr_pref = 0xc4,
        tckr_magic_no = BSR.pack [ 0x0b, 0x11, 0x09, 0x07 ],

        tckr_hd_priv_key_prefix = BSR.pack [ 0x04, 0x35, 0x83, 0x94 ],
        tckr_hd_pub_key_prefix = BSR.pack [ 0x04, 0x35, 0x87, 0xcf ],

        tckr_listen_port = 18333,

        tckr_bootstrap_host = [
            "testnet-seed.bluematt.me",
            "testnet-seed.bitcoin.jonasschnelli.ch",
            "seed.tbtc.petertodd.org",
            "seed.testnet.bitcoin.sprovoost.nl",
            "testnet-seed.bitcoin.schildbach.de"    
        ],

        tckr_genesis_raw = hex2bs "0100000000000000000000000000000000000000000000000000000000000000000000003BA3EDFD7A7B12B27AC72C3E67768F617FC81BC3888A51323A9FB8AA4B1E5E4ADAE5494DFFFF001D1AA4AE180101000000010000000000000000000000000000000000000000000000000000000000000000FFFFFFFF4D04FFFF001D0104455468652054696D65732030332F4A616E2F32303039204368616E63656C6C6F72206F6E206272696E6B206F66207365636F6E64206261696C6F757420666F722062616E6B73FFFFFFFF0100F2052A01000000434104678AFDB0FE5548271967F1A67130B7105CD6A828E03909A67962E0EA1F61DEB649F6BC3F4CEF38C4F35504E51EC112DE5C384DF7BA0B8D578A4C702B6BF11D5FAC00000000",

        tckr_use_special_min_diff = True,
        tckr_use_special_min_diff_mine = True,

        tckr_p2sh_enable_time = 1329264000,
        tckr_dup_tx_disable_time = 1329696000,

        tckr_soft_forks = [
            SoftFork {
                fork_name = "csv",
                fork_bit = 0,
                fork_start = 1456761600,
                fork_timeout = 1493568000,
                fork_status = FORK_STATUS_DEFINED
            },
            
            SoftFork {
                fork_name = "segwit",
                fork_bit = 1,
                fork_start = 1462032000,
                fork_timeout = 1493568000,
                fork_status = FORK_STATUS_DEFINED
            }
        ],
        
        tckr_bip34_height = 21111,
        tckr_bip66_height = 330776,
        tckr_bip65_height = 581885,

        tckr_reject_non_std_tx = False,

        tckr_min_tx_fee_rate = 0,

        tckr_block_assumed_valid = Nothing
            -- Just (300000, "000000000000226f7618566e70a2b5e020e29579b46743f05348427239bf41a1")
            -- Just (600000, "000000000000624f06c69d3a9fe8d25e0a9030569128d63ad1b704bbb3059a16")
            -- Just (700000, "000000000000406178b12a4dea3b27e13b3c4fe4510994fd667d7c1e6a3f4dc1")
            -- Just (750000, "000000000031067835478634e669cc6dd4cc32945542c3f6b32856999a43e37c")
            -- Just (900000, "0000000000356f8d8924556e765b7a94aaebc6b5c8685dcfa2b1ee8b41acd89b")
            -- Just (1000000, "0000000000478e259a3eda2fafbeeb0106626f946347955e99278fe6cc848414")
    }
