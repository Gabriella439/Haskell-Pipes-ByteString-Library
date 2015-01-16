{-# LANGUAGE ScopedTypeVariables #-}

module Pipes.ByteString.Builder
    ( ChunkSize
    , build
    ) where

-- | Use the 'Data.ByteString.Builder' interface to efficiently build up strict
-- 'ByteString' chunks of bounded size.

import Data.ByteString.Builder as BB
import Data.ByteString.Builder.Extra as BB
import qualified Data.ByteString as B
import Data.ByteString.Unsafe as B
import Data.Monoid
import Foreign.Marshal.Alloc (mallocBytes, free)
import Foreign.Ptr
import Pipes
import Data.Word

-- | The default size of chunks to build.
type ChunkSize = Int

data Buffer = Buffer { tailPtr :: Ptr Word8
                     , remaining :: Int
                     }

-- | Efficiently build up 'ByteString' buffers from 'Builder's of the given
-- chunk size.
build :: forall m r. MonadIO m => ChunkSize -> Producer BB.Builder m r -> Producer B.ByteString m r
build chunkSz prod0 = newBuffer chunkSz >>= \buf -> nextBuilder buf prod0
  where
    newBuffer :: Int -> Producer B.ByteString m Buffer
    newBuffer sz = do
      buf <- liftIO $ mallocBytes sz
      return $ Buffer buf sz

    -- Await the next Builder
    nextBuilder :: Buffer -> Producer BB.Builder m r -> Producer B.ByteString m r
    nextBuilder buf prod = do
      n <- lift $ next prod
      case n of
        Right (builder, prod') -> goWriter buf prod' $ BB.runBuilder builder
        Left r                 -> finishBuffer buf >> return r

    -- Execute a buffer writer until it is done
    goWriter :: Buffer -> Producer BB.Builder m r -> BB.BufferWriter -> Producer B.ByteString m r
    goWriter buf prod writer = do
      (written, nextB) <- liftIO $ writer (tailPtr buf) (remaining buf)
      case nextB of
        Done -> do
          let buf' = Buffer (tailPtr buf `plusPtr` written) (remaining buf - written)
          nextBuilder buf' prod

        More minLen writer' -> do
          finishBuffer buf
          buf' <- newBuffer (max minLen chunkSz)
          goWriter buf' prod writer'

        Chunk bs writer' -> do
          finishBuffer buf
          yield bs
          buf' <- newBuffer chunkSz
          goWriter buf' prod writer'

    -- Yield a buffer
    finishBuffer :: Buffer -> Producer B.ByteString m ()
    finishBuffer buf = do
        let written = chunkSz - remaining buf
            start = tailPtr buf `plusPtr` (-written)
        bs <- liftIO $ B.unsafePackCStringFinalizer start written (free start)
        yield bs
