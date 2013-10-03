module Haskoin.Wallet.ScriptParser
( ScriptOutput(..)
, ScriptInput(..)
, MulSig2Type(..)
, MulSig3Type(..)
, ScriptHashInput(..)
, SigHash(..)
, TxSignature(..)
, scriptAddr
, encodeInput
, decodeInput
, encodeOutput
, decodeOutput
, encodeScriptHash
, decodeScriptHash
) where

import Data.Binary
import Data.Binary.Get
import Data.Binary.Put
import qualified Data.ByteString as BS

import Haskoin.Crypto
import Haskoin.Protocol

data SigHash = SigAll    
             | SigNone   
             | SigSingle 

             -- Anyone Can Pay
             | SigAllAcp
             | SigNoneAcp
             | SigSingleAcp 
             deriving (Eq, Show)

instance Binary SigHash where

    get = do
        w <- getWord32be
        case w of 0x01 -> return SigAll
                  0x02 -> return SigNone
                  0x03 -> return SigSingle
                  0x81 -> return SigAllAcp
                  0x82 -> return SigNoneAcp
                  0x83 -> return SigSingleAcp
                  _    -> fail "Non-canonical signature: unknown hashtype byte"

    put sh = putWord32be $ case sh of
        SigAll       -> 0x01
        SigNone      -> 0x02
        SigSingle    -> 0x03
        SigAllAcp    -> 0x81
        SigNoneAcp   -> 0x82
        SigSingleAcp -> 0x83

-- Signatures in scripts contain the signature hash type byte
data TxSignature = TxSignature 
    { txSignature :: Signature 
    , sigHashType :: SigHash
    } deriving (Eq, Show)

instance Binary TxSignature where
    get = liftM2 TxSignature get get
    put (TxSignature s h) = put s >> put h

data MulSig2Type = OneOfTwo | TwoOfTwo
    deriving (Eq, Show)

data MulSig3Type = OneOfThree | TwoOfThree | ThreeOfThree
    deriving (Eq, Show)

data ScriptOutput = 
      PayPubKey     { runPayPubKey     :: !PubKey }
    | PayPubKeyHash { runPayPubKeyHash :: !Address }
    | PayMulSig1    { runPayMulSig1    :: !PubKey }
    | PayMulSig2    { mulSig2Type      :: !MulSig2Type
                    , fstMulSigKey     :: !PubKey
                    , sndMulSigKey     :: !PubKey
                    }
    | PayMulSig3    { mulSig3Type      :: !MulSig3Type
                    , fstMulSigKey     :: !PubKey
                    , sndMulSigKey     :: !PubKey
                    , trdMulSigKey     :: !PubKey
                    }
    | PayScriptHash { runPayScriptHash :: !Address }
    | PayNonStd     { runPayNonStd     :: !Script }
    deriving (Eq, Show)

scriptAddr :: ScriptOutput -> Address
scriptAddr = ScriptAddress . hash160 . hash256BS . encode' . encodeOutput
    
encodeOutput :: ScriptOutput -> Script
encodeOutput s = Script $ case s of
    (PayPubKey k) -> 
        [OP_PUSHDATA $ encode' k, OP_CHECKSIG]
    (PayPubKeyHash a) ->
        [ OP_DUP, OP_HASH160
        , OP_PUSHDATA $ encode' $ runAddress a
        , OP_EQUALVERIFY, OP_CHECKSIG
        ] 
    (PayMulSig1 k) ->
        [OP_1, OP_PUSHDATA $ encode' k, OP_1, OP_CHECKMULTISIG] 
    (PayMulSig2 t k1 k2) ->
        [ case t of
            OneOfTwo -> OP_1
            TwoOfTwo -> OP_2
        , OP_PUSHDATA $ encode' k1
        , OP_PUSHDATA $ encode' k2
        , OP_2, OP_CHECKMULTISIG
        ]
    (PayMulSig3 t k1 k2 k3) ->
        [ case t of
            OneOfThree   -> OP_1
            TwoOfThree   -> OP_2
            ThreeOfThree -> OP_3
        , OP_PUSHDATA $ encode' k1
        , OP_PUSHDATA $ encode' k2
        , OP_PUSHDATA $ encode' k3
        , OP_3, OP_CHECKMULTISIG
        ]
    (PayScriptHash a) ->
        [OP_HASH160, OP_PUSHDATA $ encode' $ runAddress a, OP_EQUAL]
    (PayNonStd ops) -> ops

decodeOutput :: Script -> ScriptOutput
decodeOutput s = case runScript s of
    [OP_PUSHDATA k, OP_CHECKSIG] -> 
        decodeEither k def PayPubKey
    [OP_DUP, OP_HASH160, OP_PUSHDATA h, OP_EQUALVERIFY, OP_CHECKSIG] -> 
        decodeEither h def (PayPubKeyHash . PubKeyAddress)
    [OP_1, OP_PUSHDATA k, OP_1, OP_CHECKMULTISIG] -> 
        decodeEither k def PayMulSig1
    [t, OP_PUSHDATA k1, OP_PUSHDATA k2, OP_2, OP_CHECKMULTISIG] -> 
        decodeEither k1 def $ \r1 -> decodeEither k2 def $ \r2 ->
            case t of OP_1 -> PayMulSig2 OneOfTwo r1 r2
                      OP_2 -> PayMulSig2 TwoOfTwo r1 r2
                      _    -> def
    [ t
    , OP_PUSHDATA k1, OP_PUSHDATA k2, OP_PUSHDATA k3
    , OP_3, OP_CHECKMULTISIG
    ] -> decodeEither k1 def $ \r1 -> 
         decodeEither k2 def $ \r2 -> 
         decodeEither k3 def $ \r3 -> 
             case t of OP_1 -> PayMulSig3 OneOfThree   r1 r2 r3
                       OP_2 -> PayMulSig3 TwoOfThree   r1 r2 r3
                       OP_3 -> PayMulSig3 ThreeOfThree r1 r2 r3
                       _    -> def
    [OP_HASH160, OP_PUSHDATA h, OP_EQUAL] -> 
        decodeEither h def (PayScriptHash . ScriptAddress)
    _ -> def
    where def = PayNonStd s

data ScriptInput = 
      SpendSig1   { runSpendSig1      :: !TxSignature }
    | SpendPKHash { runSpendPKHashSig :: !TxSignature 
                  , runSpendPKHashKey :: !PubKey
                  }
    | SpendSig2   { runSpendSig1      :: !TxSignature 
                  , runSpendSig2      :: !TxSignature
                  }
    | SpendSig3   { runSpendSig1      :: !TxSignature 
                  , runSpendSig2      :: !TxSignature 
                  , runSpendSig3      :: !TxSignature
                  }
    | SpendNonStd { runSpendNonStd    :: !Script }
    deriving (Eq, Show)

encodeInput :: ScriptInput -> Script
encodeInput s = Script $ case s of
    (SpendSig1 ts1) -> [OP_PUSHDATA $ encode' ts1]
    (SpendPKHash ts p) -> 
        [ OP_PUSHDATA $ encode' ts
        , OP_PUSHDATA $ encode' p
        ]
    (SpendSig2 ts1 ts2) -> 
        [ OP_PUSHDATA $ encode' ts1
        , OP_PUSHDATA $ encode' ts2
        ]
    (SpendSig3 ts1 ts2 ts3) -> 
        [ OP_PUSHDATA $ encode' ts1
        , OP_PUSHDATA $ encode' ts2
        , OP_PUSHDATA $ encode' ts3
        ]
    (SpendNonStd (Script ops)) -> ops

decodeInput :: Script -> ScriptInput
decodeInput s = case runScript s of
    [OP_PUSHDATA s] -> decodeEither s def SpendSig1
    [OP_PUSHDATA a, OP_PUSHDATA b] -> 
        decodeEither a def $ \s1 -> 
           if BS.head b == 0x30 
               then decodeEither b def $ \s2 -> SpendSig2 s1 s2
               else decodeEither b def $ \p  -> SpendPKHash s1 p
    [OP_PUSHDATA a, OP_PUSHDATA b, OP_PUSHDATA c] ->
        decodeEither a def $ \s1 ->
        decodeEither b def $ \s2 ->
        decodeEither c def $ \s3 -> SpendSig3 s1 s2 s3
    _ -> def
    where def = SpendNonStd s

data ScriptHashInput = ScriptHashInput 
    { spendSHInput  :: ScriptInput 
    , spendSHOutput :: ScriptOutput
    } deriving (Eq, Show)

encodeScriptHash :: ScriptHashInput -> Script
encodeScriptHash (ScriptHashInput i o) = 
    Script $ ops ++ [OP_PUSHDATA $ encode' out]
    where (Script iops) = encodeInput i
          out           = encodeOutput o

decodeScriptHash :: Script -> Maybe ScriptHashInput
decodeScriptHash s@(Script ops)
    | length ops < 2 = Nothing
    | otherwise = case last ops of
        [OP_PUSHDATA o] -> Just $ ScriptHashInput i (decodeOutput $ decode' o)
        _               -> Nothing
    where i = decodeInput $ Script $ init ops
