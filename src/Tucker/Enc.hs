{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ForeignFunctionInterface #-}

module Tucker.Enc where

import Data.Int
import Data.Bits
import Data.Word
import Data.Char
import qualified Data.Monoid as MND
import qualified Data.Foldable as FD
import qualified Data.ByteArray as BA
import qualified Data.ByteString as BSR
import qualified Data.ByteString.Lazy as LBSR
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Unsafe as BSU
import qualified Data.ByteString.Builder as BSB

import Foreign.Ptr
import Foreign.Storable hiding (sizeOf)

import System.IO.Unsafe

import Control.Monad
import Control.Exception
import Control.Monad.Catch
import Control.Applicative

import Tucker.Util
import Tucker.Error

type ByteString = BSR.ByteString
type Builder = BSB.Builder

(<>) :: Monoid a => a -> a -> a
(<>) = MND.mappend

-- mconcat :: Monoid a => [a] -> a
-- mconcat = MND.mconcat

-- mempty :: Monoid a => a
-- mempty = MND.mempty

data Placeholder = Placeholder

data Endian = LittleEndian | BigEndian deriving (Show, Read, Eq)

class Encodable t where
    -- one of encodeB and encode must be defined

    encodeB :: Endian -> t -> Builder
    encodeB end a = BSB.byteString (encode end a)

    encode :: Endian -> t -> ByteString
    encode end a = builderToBS (encodeB end a)
    
    encodeLE :: t -> ByteString
    encodeLE = encode LittleEndian

    encodeBE :: t -> ByteString
    encodeBE = encode BigEndian

    -- the result should not depend on the endianness
    -- encode in any endianness
    encodeAE :: t -> ByteString
    encodeAE = encode (error "the encoding should be endianness-irrelavent")

    encodeLEB :: t -> Builder
    encodeLEB = encodeB LittleEndian

    encodeBEB :: t -> Builder
    encodeBEB = encodeB BigEndian

    encodeAEB :: t -> Builder
    encodeAEB = encodeB (error "the encoding should be endianness-irrelavent")

instance Encodable Placeholder where
    encodeB _ _ = mempty
    encode _ _ = mempty

instance Encodable ByteString where
    encodeB _ = BSB.byteString
    encode _ = id

instance Encodable Bool where
    encodeB _ v = if v then bcharB 1 else bcharB 0
    encode _ v = if v then bchar 1 else bchar 0

instance Encodable Char where
    encodeB _ = bcharB . ord

instance Encodable Int8 where
    encodeB _ = bcharB

instance Encodable Word8 where
    encodeB _ = bcharB

instance Encodable Int16 where
    encodeB end i =
        case end of
            LittleEndian -> BSB.int16LE i
            BigEndian -> BSB.int16BE i

    encode = encodeInt 2

instance Encodable Int32 where
    encodeB end i =
        case end of
            LittleEndian -> BSB.int32LE i
            BigEndian -> BSB.int32BE i

    encode = encodeInt 4

instance Encodable Int64 where
    encodeB end i =
        case end of
            LittleEndian -> BSB.int64LE i
            BigEndian -> BSB.int64BE i

    encode = encodeInt 8

instance Encodable Word16 where
    encodeB end i =
        case end of
            LittleEndian -> BSB.word16LE i
            BigEndian -> BSB.word16BE i

    encode = encodeInt 2

instance Encodable Word32 where
    encodeB end i =
        case end of
            LittleEndian -> BSB.word32LE i
            BigEndian -> BSB.word32BE i

    encode = encodeInt 4

instance Encodable Word64 where
    encodeB end i =
        case end of
            LittleEndian -> BSB.word64LE i
            BigEndian -> BSB.word64BE i

    encode = encodeInt 8

-- encode an integer with variable length
-- to the shortest form
instance Encodable Integer where
    encode = encodeVInt

instance Encodable a => Encodable [a] where
    encodeB end = mconcat . (map (encodeB end))
    encode end = mconcat . (map (encode end))

instance Encodable a => Encodable (PartialList a) where
    encodeB end = encodeB end . FD.toList
    encode end = encode end . FD.toList

instance (Encodable t1, Encodable t2) => Encodable (t1, t2) where
    encodeB end (a, b) = encodeB end a <> encodeB end b

instance (Encodable t1, Encodable t2, Encodable t3) => Encodable (t1, t2, t3) where
    encodeB end (a, b, c) = encodeB end a <> encodeB end b <> encodeB end c

bchar :: Integral t => t -> ByteString
bchar = BSR.singleton . fromIntegral

bcharB :: Integral t => t -> Builder
bcharB = BSB.word8 . fromIntegral

-- encode integer to the shortest possible encoding
-- using 2's complement
encodeVInt' :: Endian -> Integer -> ByteString
encodeVInt' end 0 = BSR.empty
encodeVInt' end (-1) = bchar 0xff
encodeVInt' end num =
    case end of
        LittleEndian -> BSR.reverse res
        BigEndian -> res
    where
        pred (bs, num) = not $
            (num == 0 || num == -1) &&
            not (BSR.null bs) &&
            (BSR.head bs < 0x80) == (num >= 0) -- sign is correct

        res =
            -- BSR.dropWhile (== 0) $
            fst $ head $
            dropWhile pred $
            flip iterate (BSR.empty, num) $ \(bs, num) ->
                let least = num .&. 0xff
                in  (BSR.cons (fi least) bs, num `shiftR` 8)

-- encode int to an indefinite size
-- inverse of decodeVInt
encodeVInt :: (Integral t, Bits t) => Endian -> t -> ByteString
encodeVInt end num = encodeVInt' end (fi num)

-- similar to encodeVInt
-- but it will trim all unnecessary zero bytes
-- from the high end
-- inverse of decodeVWord
encodeVWord :: (Integral t, Bits t) => Endian -> t -> ByteString
encodeVWord end num =
    case end of
        LittleEndian -> BSR.reverse $ BSR.dropWhile (== 0) $ BSR.reverse res
        BigEndian -> BSR.dropWhile (== 0) res
    where res = encodeVInt' end (fi num)

builderToBS = LBSR.toStrict . BSB.toLazyByteString

-- fast encode

type CEndian = Int8

toCEndian LittleEndian = 1
toCEndian BigEndian = 0

foreign import ccall "fast_encode_word16" c_fast_encode_word16 :: Ptr Word8 -> CEndian -> Word16 -> IO ()
foreign import ccall "fast_encode_word32" c_fast_encode_word32 :: Ptr Word8 -> CEndian -> Word32 -> IO ()
foreign import ccall "fast_encode_word64" c_fast_encode_word64 :: Ptr Word8 -> CEndian -> Word64 -> IO ()

fastEncodeWord8 _ num = bchar (num :: Word8)

fastEncodeWord16 end n =
    snd $ unsafePerformIO $
    BA.allocRet 2 $ \p ->
        c_fast_encode_word16 p (toCEndian end) n
    
fastEncodeWord32 end n =
    snd $ unsafePerformIO $
    BA.allocRet 4 $ \p ->
        c_fast_encode_word32 p (toCEndian end) n

fastEncodeWord64 end n =
    snd $ unsafePerformIO $
    BA.allocRet 8 $ \p ->
        c_fast_encode_word64 p (toCEndian end) n

{-# INLINE fastEncodeWord8 #-}
{-# INLINE fastEncodeWord16 #-}
{-# INLINE fastEncodeWord32 #-}
{-# INLINE fastEncodeWord64 #-}

-- encode int to a fixed-size string(will truncate/fill the resultant string)
encodeInt :: (Integral t, Bits t) => Int -> Endian -> t -> ByteString

encodeInt 1 end num = fastEncodeWord8 end (fi num)
encodeInt 2 end num = fastEncodeWord16 end (fi num)
encodeInt 4 end num = fastEncodeWord32 end (fi num)
encodeInt 8 end num = fastEncodeWord64 end (fi num)

encodeInt nbyte end num =
    if diff > 0 then -- fill
        if num < 0 then BSR.replicate diff 0xff `fill` res
        else BSR.replicate diff 0x00 `fill` res
    else
        case end of
            LittleEndian -> BSR.take nbyte res
            BigEndian -> BSR.drop (len - nbyte) res

    where res = encodeVInt end num
          len = BSR.length res
          diff = nbyte - len
          fill pref a =
              case end of
                  LittleEndian -> a <> pref
                  BigEndian -> pref <> a

decodeInt' :: Integer -> Endian -> ByteString -> Integer
decodeInt' init LittleEndian = BSR.foldr' (\x a -> shiftL a 8 + fi x) init
decodeInt' init BigEndian = BSR.foldl' (\a x -> shiftL a 8 + fi x) init

-- fast decoder

foreign import ccall "fast_decode_word16" c_fast_decode_word16 :: Ptr Word8 -> CEndian -> IO Word16
foreign import ccall "fast_decode_word32" c_fast_decode_word32 :: Ptr Word8 -> CEndian -> IO Word32
foreign import ccall "fast_decode_word64" c_fast_decode_word64 :: Ptr Word8 -> CEndian -> IO Word64

fastDecodeWord8 _ bs = BSR.head bs
fastDecodeWord16 end bs =
    unsafePerformIO $
    BA.withByteArray bs $ \p ->
        c_fast_decode_word16 p (toCEndian end)
    
fastDecodeWord32 end bs =
    unsafePerformIO $
    BA.withByteArray bs $ \p ->
        c_fast_decode_word32 p (toCEndian end)

fastDecodeWord64 end bs =
    unsafePerformIO $
    BA.withByteArray bs $ \p ->
        c_fast_decode_word64 p (toCEndian end)

fastDecodeInt8 end bs = fi (fastDecodeWord8 end bs) :: Int8
fastDecodeInt16 end bs = fi (fastDecodeWord16 end bs) :: Int16
fastDecodeInt32 end bs = fi (fastDecodeWord32 end bs) :: Int32
fastDecodeInt64 end bs = fi (fastDecodeWord64 end bs) :: Int64

{-# INLINE fastDecodeInt8 #-}
{-# INLINE fastDecodeInt16 #-}
{-# INLINE fastDecodeInt32 #-}
{-# INLINE fastDecodeInt64 #-}
{-# INLINE fastDecodeWord8 #-}
{-# INLINE fastDecodeWord16 #-}
{-# INLINE fastDecodeWord32 #-}
{-# INLINE fastDecodeWord64 #-}

-- decodes a bytestring as an integer and determines the sign
decodeVInt :: Integral t => Endian -> ByteString -> t
decodeVInt end bs =
    case BSR.length bs of
        0 -> 0
        1 -> fi (fastDecodeInt8 end bs)
        2 -> fi (fastDecodeInt16 end bs)
        4 -> fi (fastDecodeInt32 end bs)
        8 -> fi (fastDecodeInt64 end bs)
        _ ->
            if sign < 0x80 then fi (decodeInt' 0 end bs)
            else fi (decodeInt' (-1) end bs)
    where
        sign = case end of
            LittleEndian -> BSR.last bs
            BigEndian -> BSR.head bs

-- similar to above, but doesn't care about the sign
decodeVWord :: Integral t => Endian -> ByteString -> t
decodeVWord end bs =
    case BSR.length bs of
        0 -> 0
        -- NOTE: cannot swap with fastDecodeInt here because
        -- the sign extension may change the intended value
        1 -> fi (fastDecodeWord8 end bs)
        2 -> fi (fastDecodeWord16 end bs)
        4 -> fi (fastDecodeWord32 end bs)
        8 -> fi (fastDecodeWord64 end bs)
        _ -> fi (decodeInt' 0 end bs)

-- turn a negative Integer to a unsigned positive Integer
toUnsigned :: Integer -> Integer
toUnsigned int =
    if int >= 0 then int
    else decodeVWord LittleEndian (encodeVInt LittleEndian int)

-- little-endian
bs2vwordLE :: ByteString -> Integer
bs2vwordLE = decodeVWord LittleEndian

vword2bsLE :: Integer -> ByteString
vword2bsLE = encodeVWord LittleEndian

-- big-endian
bs2vwordBE :: ByteString -> Integer
bs2vwordBE = decodeVWord BigEndian

vword2bsBE :: Integer -> ByteString
vword2bsBE = encodeVWord BigEndian

-- decoding
newtype Decoder r = Decoder { decode_proc :: Endian -> ByteString -> (Either TCKRError r, ByteString) }

instance Functor Decoder where
    -- fmap f (Parser ps) = Parser $ \p -> [ (f a, b) | (a, b) <- ps p ]
    fmap f (Decoder d) =
        Decoder $ \end bs ->
            case d end bs of
                (Right r, rest) -> (Right (f r), rest)
                (Left err, rest) -> (Left err, rest)

instance Applicative Decoder where
    pure res = Decoder $ \end rest -> (Right res, rest)

    Decoder d1 <*> Decoder d2 =
        Decoder $ \end bs ->
            case d1 end bs of
                (Right f, rest) ->
                    case d2 end rest of
                        (Right r, rest) -> (Right (f r), rest)
                        (Left err, rest) -> (Left err, rest)

                (Left err, rest) -> (Left err, rest)

instance Monad Decoder where
    return = pure

    fail err = Decoder $ \end bs -> (Left $ TCKRError err, bs)

    Decoder d >>= f =
        Decoder $ \end bs ->
            case d end bs of
                (Right r, rest) -> decode_proc (f r) end rest
                (Left err, rest) -> (Left err, rest)

instance Alternative Decoder where
    empty = fail "empty decoder"
    Decoder d1 <|> Decoder d2 =
        Decoder $ \end bs ->
            case d1 end bs of
                r@(Right _, rest) -> r
                (Left e1, _) ->
                    case d2 end bs of
                        r@(Right _, rest) -> r
                        (Left e2, rest) ->
                            (Left $ wrapError e2 (show e1), rest)

instance MonadThrow Decoder where
    throwM = fail . show

instance MonadCatch Decoder where
    catch d proc =
        Decoder $ \end bs ->
            case decode_proc d end bs of
                r@(Right _, _) -> r
                r@(Left exc, _) ->
                    case fromException $ toException exc of
                        Nothing -> r
                        Just e -> decode_proc (proc e) end bs

class Decodable t where
    decoder :: Decoder t

    decoderLE :: Decoder t
    decoderLE = Decoder $ \_ -> decodeLE

    decoderBE :: Decoder t
    decoderBE = Decoder $ \_ -> decodeBE

    decode :: Endian -> ByteString -> (Either TCKRError t, ByteString)
    decode = decode_proc decoder

    decodeLE :: ByteString -> (Either TCKRError t, ByteString)
    decodeLE = decode LittleEndian

    decodeBE :: ByteString -> (Either TCKRError t, ByteString)
    decodeBE = decode BigEndian

    decodeAllLE :: ByteString -> Either TCKRError t
    decodeAllLE = fst . decodeLE

    decodeAllBE :: ByteString -> Either TCKRError t
    decodeAllBE = fst . decodeBE

    decodeFailLE :: ByteString -> t
    decodeFailLE = either throw id . decodeAllLE

    decodeFailBE :: ByteString -> t
    decodeFailBE = either throw id . decodeAllBE

runDecoderFailLE :: Decoder t -> ByteString -> t
runDecoderFailLE d = either throw id . fst . decode_proc d LittleEndian

runDecoderFailBE :: Decoder t -> ByteString -> t
runDecoderFailBE d = either throw id . fst . decode_proc d BigEndian

intD :: Integral t => Int -> Decoder t
intD nbyte = Decoder $ \end bs ->
    if BSR.length bs >= nbyte then
        (Right $ decodeVInt end (BSR.take nbyte bs), BSR.drop nbyte bs)
    else
        (Left $ TCKRError
            ("no enough byte for a " ++ (show nbyte) ++ "-byte int"), bs)

wordD :: Integral t => Int -> Decoder t
wordD nbyte = Decoder $ \end bs ->
    if BSR.length bs >= nbyte then
        (Right $ decodeVWord end (BSR.take nbyte bs), BSR.drop nbyte bs)
    else
        (Left $ TCKRError
            ("no enough byte for a " ++ (show nbyte) ++ "-byte word"), bs)

byteD :: Decoder Word8
byteD =
    Decoder $ \_ bs ->
        if BSR.length bs >= 1 then
            (Right $ BSR.head bs, BSR.tail bs)
        else
            (Left $ TCKRError "need 1 byte", bs)

beginWithByteD :: Word8 -> Decoder ()
beginWithByteD byte =
    Decoder $ \_ bs ->
        if BSR.length bs >= 1 then
            if BSR.head bs == byte then
                (Right (), BSR.tail bs)
            else
                (Left $ TCKRError "first byte not match", bs)
        else
            (Left $ TCKRError "need 1 byte", bs)

bsD :: Int -> Decoder ByteString
bsD len =
    Decoder $ \_ bs ->
        if BSR.length bs >= len then
            (Right $ BSR.take len bs, BSR.drop len bs)
        else
            (Left $ TCKRError ("need " ++ (show len) ++ " byte(s)"), bs)

peekByteD :: Decoder Word8
peekByteD =
    Decoder $ \_ bs ->
        if BSR.length bs >= 1 then
            (Right $ BSR.head bs, bs)
        else
            (Left $ TCKRError "peek need 1 byte", bs)

listD :: Int -> Decoder t -> Decoder [t]
listD = replicateM
    -- forM [ 1 .. len ] (\l -> tLnM (show l >> d))
    -- replicateM

lenD :: Decoder Int
lenD = Decoder $ \_ bs -> (Right $ BSR.length bs, bs)

checkLenD :: Int -> Decoder Bool
checkLenD len = (len <=) <$> lenD

ifD :: Bool -> t -> Decoder t -> Decoder t
ifD cond t d = if cond then return t else d

-- append a bytestring to the parsing buffer
appendD :: ByteString -> Decoder ()
appendD bs = Decoder $ \_ orig -> (Right (), BSR.append bs orig)

forceEndian :: Endian -> Decoder a -> Decoder a
forceEndian end (Decoder d) =
    Decoder $ \_ bs -> d end bs

allD :: Decoder ByteString
allD = Decoder $ \_ bs -> (Right bs, BSR.empty)

allD' :: Decoder ByteString
allD' = Decoder $ \_ bs -> (Right bs, bs)

getD = allD'

putD :: ByteString -> Decoder ()
putD bs = Decoder $ \_ _ -> (Right (), bs)

-- only feed part of the current bs to the given decoder
quota :: Int -> Decoder t -> Decoder t
quota len d =
    Decoder $ \end bs ->
        let part = BSR.take len bs
            (res, rest) = decode_proc d end part
        in (res, rest <> BSR.drop len bs)

instance Decodable Placeholder where
    decoder = return Placeholder

instance Decodable Bool where
    decoder = do
        c <- byteD
        case c of
            0x00 -> return False
            0x01 -> return True
            _ -> fail "illegal bool"

instance Decodable Char where
    decoder = (chr. fromIntegral) <$> byteD

instance Decodable Int8 where
    decoder = fromIntegral <$> byteD

instance Decodable Word8 where
    decoder = byteD

instance Decodable Int16 where
    decoder = intD 2

instance Decodable Int32 where
    decoder = intD 4

instance Decodable Int64 where
    decoder = intD 8

instance Decodable Word16 where
    decoder = wordD 2

instance Decodable Word32 where
    decoder = wordD 4

instance Decodable Word64 where
    decoder = wordD 8

instance (Decodable t1, Decodable t2) => Decodable (t1, t2) where
    decoder = (,) <$> decoder <*> decoder

instance Decodable String where
    decoder = BS.unpack <$> allD

instance Decodable Integer where
    decoder = Decoder $ \end bs ->
        (Right (decodeVInt end bs), BSR.empty)

instance Decodable ByteString where
    decoder = allD

-- -- decode as many t as possible
-- instance Decodable t => Decodable [t] where
--     decoder = many decoder

-- sizes

instance Sizeable Placeholder where
    sizeOf _ = 0

instance Sizeable ByteString where
    sizeOf = BSR.length

instance Sizeable Bool where
    sizeOf _ = 1

instance Sizeable Char where
    sizeOf _ = 1

instance Sizeable Int8 where
    sizeOf _ = 1

instance Sizeable Word8 where
    sizeOf _ = 1

instance Sizeable Int16 where
    sizeOf _ = 2

instance Sizeable Int32 where
    sizeOf _ = 4

instance Sizeable Int64 where
    sizeOf _ = 8

instance Sizeable Word16 where
    sizeOf _ = 2

instance Sizeable Word32 where
    sizeOf _ = 4

instance Sizeable Word64 where
    sizeOf _ = 8

-- encode an integer with variable length
-- to the shortest form
instance Sizeable Integer where
    sizeOf = BSR.length . encodeLE

instance Sizeable a => Sizeable [a] where
    sizeOf = sum . map sizeOf

instance Sizeable a => Sizeable (PartialList a) where
    sizeOf = sum . map sizeOf . FD.toList

instance (Sizeable t1, Sizeable t2) => Sizeable (t1, t2) where
    sizeOf (a, b) = sizeOf a + sizeOf b

instance (Sizeable t1, Sizeable t2, Sizeable t3) => Sizeable (t1, t2, t3) where
    sizeOf (a, b, c) = sizeOf a + sizeOf b + sizeOf c
