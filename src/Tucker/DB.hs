{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances, MultiParamTypeClasses #-}

-- key-value db wrapper with keyspace

module Tucker.DB where

import Data.Hex
import Data.Word
import qualified Data.ByteString as BSR
import qualified Data.ByteString.Char8 as BS

import qualified Database.LevelDB as D

import System.FilePath
import System.Directory

import Control.Monad
import Control.Monad.Morph
import Control.Monad.Loops
import Control.Monad.Trans.Resource

import Tucker.Enc
import Tucker.Util
import Tucker.Atom

import Tucker.Container.IOMap

type Database = D.DB

type DBOption = D.Options
type DBOptionR = D.ReadOptions
type DBOptionW = D.WriteOptions

-- type DBKeySpace = ByteString

optMaxFile :: Int -> DBOption -> DBOption
optMaxFile max_file opt =
    opt {
        D.maxOpenFiles = max_file
    }

optCreateIfMissing :: Bool -> DBOption -> DBOption
optCreateIfMissing v opt =
    opt {
        D.createIfMissing = v
    }

instance Default DBOption where
    def = D.defaultOptions {
        D.createIfMissing = True,
        D.maxOpenFiles = 64
        -- D.cacheSize = 4, -- 16k
        -- D.writeBufferSize = 4 -- 512K
    }

instance Default DBOptionR where
    def = D.defaultReadOptions

instance Default DBOptionW where
    def = D.defaultWriteOptions

openDB :: DBOption -> FilePath -> ResIO Database
openDB opt path = do
    lift $
        if D.createIfMissing opt then
            createDirectoryIfMissing True path
        else
            return ()

    D.open path opt

withDB :: DBOption -> FilePath -> (Database -> IO a) -> IO a
withDB opt path proc = runResourceT $
    openDB opt path >>= (lift . proc)

instance IOMap Database ByteString ByteString where
    lookupIO = lookupWithOption def
    insertIO = insertWithOption def
    deleteIO = deleteWithOption def

    foldKeyIO db init proc = runResourceT $ do
        iter <- D.iterOpen db (def { D.fillCache = False })
    
        lift $ D.iterFirst iter
    
        (res, _) <- lift $ flip (iterateUntilM snd) (init, False) $
            \(init, valid) -> do
                -- valid <- D.iterValid iter
                mkey <- D.iterKey iter

                next <- case mkey of
                    Nothing -> return init
                    Just key -> proc init key

                D.iterNext iter

                return (next, not $ maybeToBool mkey)
    
        return res

lookupWithOption :: DBOptionR -> Database -> ByteString -> IO (Maybe ByteString)
lookupWithOption opt db key = D.get db opt key

insertWithOption :: DBOptionW -> Database -> ByteString -> ByteString -> IO ()
insertWithOption opt db key val = D.put db opt key val

deleteWithOption :: DBOptionW -> Database -> ByteString -> IO ()
deleteWithOption opt db key = D.delete db opt key

data DBBucket k v =
    DBBucket {
        bucket_pref :: ByteString,
        raw_db      :: Database
    }

instance Show (DBBucket k v) where
    show bucket = "Bucket " ++ show (hex (bucket_pref bucket))

withPrefix :: [Word32] -> String -> ByteString
withPrefix prefs name =
    encodeLE prefs <> BS.pack name

key_bucket_count = withPrefix [ 0, 0 ] "bucket_count"
key_bucket name = withPrefix [ 0, 1 ] name

-- buckets are virtual keyspaces across in a database
-- bucket names are encoded to a 4-byte prefix for each entry
-- the prefix starts with 0x1(all in little endian)
-- 0x0000 ++ 0x0000 ++ "bucket_count" -> total bucket count
-- 0x0000 ++ 0x0001 ++ <bucket_name> -> prefix for bucket <bucket_name>
openBucket :: Database -> String -> IO (DBBucket k v)
openBucket db name = do
    pref <- lookupIO db (key_bucket name)

    pref <- case pref of
        Just pref -> return pref
        Nothing -> do
            -- bucket does not exist
            count <- maybe 0 decodeFailLE <$> lookupIO db key_bucket_count
            
            let pref = encodeLE (count + 1 :: Word32)

            insertIO db key_bucket_count pref
            insertIO db (key_bucket name) pref

            return pref

    -- buffer_map <- newA Nothing

    return $ DBBucket {
        bucket_pref = pref,
        raw_db = db
        -- buffer_map = buffer_map
    }

instance (Encodable k, Decodable k, Encodable v, Decodable v)
         => IOMap (DBBucket k v) k v where
    lookupIO = lookupAsIO
    insertIO = insertAsIO
    deleteIO (DBBucket pref db) k = deleteIO db (pref <> encodeLE k)

    foldKeyIO (DBBucket pref db) init proc =
        foldKeyIO db init $ \init k ->
            if pref `BSR.isPrefixOf` k then
                proc init (decodeFailLE (BSR.drop (BSR.length pref) k))
            else
                return init

-- assuming
-- forall i, j. bucket has i and bucket doesn't have j => i < j
-- returning the minimum e such that bucket doesn't have e
quickCountIO :: (Encodable t, Decodable t,
                 Encodable v, Decodable v,
                 Show t, Integral t) => DBBucket t v -> IO t
quickCountIO bucket = do
    Just hi <- flip firstM [ 2 ^ n | n <- [0..] ] $ \i ->
        isNothing <$> lookupIO bucket i

    let lo = hi `div` 2
        comp i = do
            -- tLnM ("searching " ++ show i)

            next <- isJust <$> lookupIO bucket i
            edge <- isJust <$> lookupIO bucket (i - 1)
    
            return $
                if next then GT
                else
                    if edge then EQ
                    else LT

    -- tLnM ("[" ++ show lo ++ ", " ++ show hi ++ ")")

    maybe 0 id <$> binarySearchIO comp lo hi

-- lookup a key and return differently decoded value
-- ONLY supported for DBBucket
lookupAsIO :: (Encodable k, Decodable v') => DBBucket k v -> k -> IO (Maybe v')
lookupAsIO (DBBucket pref db) k = do
    mres <- lookupIO db (pref <> encodeLE k)
    return (decodeFailLE <$> mres)

insertAsIO :: (Encodable k, Encodable v') => DBBucket k v -> k -> v' -> IO ()
insertAsIO (DBBucket pref db) k v =
    insertIO db (pref <> encodeLE k) (encodeLE v)

type DBEntry = DBBucket Placeholder
