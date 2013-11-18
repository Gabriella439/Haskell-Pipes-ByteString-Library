-- | Parsing utilities for bytestrings, in the style of @pipes-parse@

module Pipes.ByteString.Parse (
    -- * Parsers
      nextByte
    , drawByte
    , unDrawByte
    , peekByte
    , isEndOfBytes
    , take
    , takeWhile
    ) where

import Control.Monad.Trans.State.Strict (StateT, modify)
import qualified Data.ByteString as BS
import Data.ByteString (ByteString)
import Data.ByteString.Unsafe (unsafeTake, unsafeDrop)
import Data.Word (Word8)
import Pipes
import qualified Pipes.Parse as PP

import Prelude hiding (take, takeWhile)

{-| Consume the first byte from a byte stream

    'next' either fails with a 'Left' if the 'Producer' has no more bytes or
    succeeds with a 'Right' providing the next byte and the remainder of the
    'Producer'.
-}
nextByte
    :: (Monad m)
    => Producer ByteString m r
    -> m (Either r (Word8, Producer ByteString m r))
nextByte = go
  where
    go p = do
        x <- next p
        case x of
            Left   r       -> return (Left r)
            Right (bs, p') -> case (BS.uncons bs) of
                Nothing        -> go p'
                Just (w8, bs') -> return (Right (w8, yield bs' >> p'))
{-# INLINABLE nextByte #-}

{-| Draw one 'Word8' from the underlying 'Producer', returning 'Left' if the
    'Producer' is empty
-}
drawByte :: (Monad m) => StateT (Producer ByteString m r) m (Either r Word8)
drawByte = do
    x <- PP.draw
    case x of
        Left  r  -> return (Left r)
        Right bs -> case (BS.uncons bs) of
            Nothing        -> drawByte
            Just (w8, bs') -> do
                PP.unDraw bs'
                return (Right w8)
{-# INLINABLE drawByte #-}

-- | Push back a 'Word8' onto the underlying 'Producer'
unDrawByte :: (Monad m) => Word8 -> StateT (Producer ByteString m r) m ()
unDrawByte w8 = modify (yield (BS.singleton w8) >>)
{-# INLINABLE unDrawByte #-}

{-| 'peekByte' checks the first 'Word8' in the stream, but uses 'unDrawByte' to
    push the 'Word8' back

> peekByte = do
>     x <- drawByte
>     case x of
>         Left  _  -> return ()
>         Right w8 -> unDrawByte w8
>     return x
-}
peekByte :: (Monad m) => StateT (Producer ByteString m r) m (Either r Word8)
peekByte = do
    x <- drawByte
    case x of
        Left  _  -> return ()
        Right w8 -> unDrawByte w8
    return x
{-# INLINABLE peekByte #-}

{-| Check if the underlying 'Producer' has no more bytes

    Note that this will skip over empty 'ByteString' chunks, unlike
    'PP.isEndOfInput' from @pipes-parse@.

> isEndOfBytes = liftM isLeft peekByte
-}
isEndOfBytes :: (Monad m) => StateT (Producer ByteString m r) m Bool
isEndOfBytes = do
    x <- peekByte
    return (case x of
        Left  _ -> True
        Right _ -> False )
{-# INLINABLE isEndOfBytes #-}

{-| @(take n)@ only allows @n@ bytes to pass

    Unlike @Pipes.ByteString.'Pipes.ByteString.take'@, this 'PP.unDraw's unused
    bytes
-}
take :: (Monad m, Integral a) => a -> Pipe ByteString ByteString (StateT (Producer ByteString m r) m) ()
take n0 = go n0 where
    go n
        | n <= 0 = return ()
        | otherwise = do
            bs <- await
            let len = fromIntegral (BS.length bs)
            if (len > n)
                then do
                    let n' = fromIntegral n
                    lift . PP.unDraw $ unsafeDrop n' bs
                    yield $ unsafeTake n' bs
                else do
                    yield bs
                    go (n - len)
{-# INLINABLE take #-}

{-| Take bytes until they fail the predicate

    Unlike @Pipes.ByteString.'Pipes.ByteString.takeWhile'@, this 'PP.unDraw's
    unused bytes
-}
takeWhile
    :: (Monad m)
    => (Word8 -> Bool)
    -> Pipe ByteString ByteString (StateT (Producer ByteString m r) m) ()
takeWhile predicate = go
  where
    go = do
        bs <- await
        let (prefix, suffix) = BS.span predicate bs
        if (BS.null suffix)
            then do
                yield bs
                go
            else do
                lift $ PP.unDraw suffix
                yield prefix
{-# INLINABLE takeWhile #-}
