module Tucker.Msg.Other where

import Data.Word
import qualified Data.ByteString as BSR

import Control.Exception

import Tucker.Enc
import Tucker.DeepSeq
import Tucker.Msg.Common

newtype PingPongPayload = PingPongPayload Word64 deriving (Show, Eq)

instance MsgPayload PingPongPayload

instance Encodable PingPongPayload where
    encodeB end (PingPongPayload nonce) = encodeB end nonce

instance Decodable PingPongPayload where
    decoder = decoder >>= return . PingPongPayload

data RejectType
    = REJECT_MALFORMED
    | REJECT_INVALID
    | REJECT_OBSOLETE
    | REJECT_DUPLICATE
    | REJECT_NONSTANDARD
    | REJECT_DUST
    | REJECT_INSUFFICIENTFEE
    | REJECT_CHECKPOINT deriving (Show, Eq)
        
reject_type_map = [
        (REJECT_MALFORMED,       0x01),
        (REJECT_INVALID,         0x10),
        (REJECT_OBSOLETE,        0x11),
        (REJECT_DUPLICATE,       0x12),
        (REJECT_NONSTANDARD,     0x40),
        (REJECT_DUST,            0x41),
        (REJECT_INSUFFICIENTFEE, 0x42),
        (REJECT_CHECKPOINT,      0x43)
    ]

reject_type_map_r = map (\(a, b) -> (b, a)) reject_type_map

instance MsgPayload RejectPayload

instance Encodable RejectType where
    encodeB end t =
        case lookup t reject_type_map of
            Just i -> encodeB end (i :: Word8)
            Nothing -> error "reject type not exist"

instance Decodable RejectType where
    decoder = do
        i <- byteD
        case lookup i reject_type_map_r of
            Just t -> return t
            Nothing -> fail $ "reject type " ++ (show i) ++ " not exist"

data RejectPayload =
    RejectPayload {
        message :: String,
        ccode   :: RejectType,
        reason  :: String,
        rdata   :: ByteString
    } deriving (Show, Eq)

instance Encodable RejectPayload where
    encodeB end (RejectPayload {
        message = message,
        ccode = ccode,
        reason = reason,
        rdata = rdata
    }) =
        e (vstr message) <> e ccode <>
        e (vstr reason) <> e rdata
        where
            e :: Encodable t => t -> Builder
            e = encodeB end

instance Decodable RejectPayload where
    decoder = do
        message <- decoder
        ccode <- decoder
        reason <- decoder
        rdata <- allD -- eat the rest
        return $ RejectPayload {
            message = vstrToString message,
            ccode = ccode,
            reason = vstrToString reason,
            rdata = rdata
        }

data Rejection = Rejection RejectType String deriving (Show)

instance Exception Rejection

instance NFData Rejection where
    rnf (Rejection t m) = t `seq` rnf m

newtype AlertPayload = AlertPayload ByteString deriving (Show, Eq)

-- instance Encodable AlertPayload where

instance Decodable AlertPayload where
    decoder = allD >>= return . AlertPayload

encodeRejectPayload :: Command -> ByteString -> Rejection -> IO ByteString
encodeRejectPayload cmd dat (Rejection rtype msg) =
    return $ encodeLE RejectPayload {
        message = commandToString cmd,
        ccode = rtype,
        reason = msg,
        rdata = dat
    }
