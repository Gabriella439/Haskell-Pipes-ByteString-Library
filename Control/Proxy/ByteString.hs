module Control.Proxy.ByteString where

import Control.Monad (forever)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Writer.Strict (WriterT, tell)
import Control.Proxy hiding (mapD, takeWhileD, dropWhileD)
import qualified Control.Proxy as P
import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as BU
import Data.Monoid (All(All), Any(Any), Sum(Sum))
import Data.Int (Int64)
import Data.Word (Word8)
import System.IO (Handle, hIsEOF)

defaultChunkSize :: Int
defaultChunkSize = 4096

packS :: (Monad m, ProxyP p) => [Word8] -> () -> Producer p B.ByteString m ()
packS w8s () = runIdentityP $ respond (B.pack w8s)

unpackD
 :: (Monad m, ProxyP p)
 => x -> p x B.ByteString x B.ByteString (WriterT [Word8] m) r
unpackD = runIdentityK $ foreverK $ \x -> do
    bs <- request x
    lift $ tell $ B.unpack bs
    respond bs

fromStrictS
 :: (Monad m, ProxyP p) => B.ByteString -> () -> Producer p B.ByteString m ()
fromStrictS bs () = runIdentityP $ respond bs

toStrictD
 :: (Monad m, ProxyP p)
 => x -> p x B.ByteString x B.ByteString (WriterT B.ByteString m) r
toStrictD = runIdentityK $ foreverK $ \x -> do
    bs <- request x
    lift $ tell bs
    respond bs

fromChunksS
 :: (Monad m, ProxyP p) => [B.ByteString] -> () -> Producer p B.ByteString m ()
fromChunksS = fromListS

toChunksD
 :: (Monad m, ProxyP p)
 => x -> p x B.ByteString x B.ByteString (WriterT [B.ByteString] m) r
toChunksD = runIdentityK $ foreverK $ \x -> do
    bs <- request x
    lift $ tell [bs]
    respond bs

tailD :: (Monad m, ProxyP p) => x -> p x B.ByteString x B.ByteString m r
tailD = runIdentityK go where
    go = \x -> do
        bs <- request x
        if (B.null bs)
            then do
                x2 <- respond bs
                go x2
            else do
                x2 <- respond (BU.unsafeTail bs)
                idT x2

-- | Fold that returns whether 'All' received 'ByteString's are empty
nullD
 :: (Monad m, ProxyP p)
 => x -> p x B.ByteString x B.ByteString (WriterT All m) r
nullD = runIdentityK $ foreverK $ \x -> do
    bs <- request x
    lift $ tell $ All $ B.null bs
    respond bs

{-| Fold that returns whether 'All' received 'ByteString's are empty

    'nullD_' terminates on the first non-empty 'ByteString'. -}
nullD_
 :: (Monad m, ProxyP p)
 => x -> p x B.ByteString x B.ByteString (WriterT All m) ()
nullD_ = runIdentityK go where
    go x = do
        bs <- request x
        if (B.null bs)
            then do
                x2 <- respond bs
                go x2
            else lift $ tell $ All False

lengthD
 :: (Monad m, ProxyP p)
 => x -> p x B.ByteString x B.ByteString (WriterT (Sum Int) m) r
lengthD = runIdentityK $ foreverK $ \x -> do
    bs <- request x
    lift $ tell $ Sum $ B.length bs
    respond bs

mapD
 :: (Monad m, ProxyP p)
 => (Word8 -> Word8) -> x -> p x B.ByteString x B.ByteString m r
mapD f = P.mapD (B.map f)

intersperseD
 :: (Monad m, ProxyP p) => Word8 -> () -> Pipe p B.ByteString B.ByteString m r
intersperseD w8 () = runIdentityP $ do
    bs0 <- request ()
    respond (B.intersperse w8 bs0)
    forever $ do
        respond (B.singleton w8)
        bs <- request ()
        respond (B.intersperse w8 bs)

intercalateD :: (Monad m, ProxyP p)
 => B.ByteString -> () -> Pipe p B.ByteString B.ByteString m r
intercalateD bsi () = runIdentityP $ do
    bs0 <- request ()
    respond bs0
    forever $ do
        bs <- request ()
        respond bsi
        respond bs

concatMapD
 :: (Monad m, ProxyP p)
 => (Word8 -> B.ByteString) -> x -> p x B.ByteString x B.ByteString m r
concatMapD f = P.mapD (B.concatMap f)

-- | Fold that returns whether 'Any' received 'Word8's satisfy the predicate
anyD
 :: (Monad m, ProxyP p)
 => (Word8 -> Bool) -> x -> p x B.ByteString x B.ByteString (WriterT Any m) r
anyD pred = runIdentityK $ foreverK $ \x -> do
    bs <- request x
    lift $ tell $ Any $ B.any pred bs
    respond bs

{-| Fold that returns whether 'Any' received 'Word8's satisfy the predicate

    'anyD_' terminates on the first 'Word8' that satisfies the predicate. -}
anyD_
 :: (Monad m, ProxyP p)
 => (Word8 -> Bool) -> x -> p x B.ByteString x B.ByteString (WriterT Any m) ()
anyD_ pred = runIdentityK go where
    go x = do
        bs <- request x
        if (B.any pred bs)
            then lift $ tell $ Any True
            else do
                x2 <- respond bs
                go x2

-- | Fold that returns whether 'All' received 'Word8's satisfy the predicate
allD
 :: (Monad m, ProxyP p)
 => (Word8 -> Bool) -> x -> p x B.ByteString x B.ByteString (WriterT All m) r
allD pred = runIdentityK $ foreverK $ \x -> do
    bs <- request x
    lift $ tell $ All $ B.all pred bs
    respond bs

{-| Fold that returns whether 'All' received 'Word8's satisfy the predicate

    'allD_' terminates on the first 'Word8' that fails the predicate. -}
allD_
 :: (Monad m, ProxyP p)
 => (Word8 -> Bool) -> x -> p x B.ByteString x B.ByteString (WriterT All m) ()
allD_ pred = runIdentityK go where
    go x = do
        bs <- request x
        if (B.all pred bs)
            then do
                x2 <- respond bs
                go x2
            else lift $ tell $ All False

{-
newtype Maximum a = Maximum { getMaximum :: Maybe a }

instance (Ord a) => Monoid (Maximum a) where
    mempty = Maximum Nothing
    mappend m1 (Maximum Nothing) = m1
    mappend (Maximum Nothing) m2 = m2
    mappend (Maximum (Just a1)) (Maximum (Just a2)) = Maximum (Just (max a1 a2))

maximumD
 :: (Monad m, ProxyP p)
 => x -> p x B.ByteString x B.ByteString (WriterT (Maximum Word8) m) r
maximumD = runIdentityK $ foreverK $ \x -> do
    bs <- request x
    lift $ tell $ Maximum $ Just $ B.maximum bs
    respond bs

newtype Minimum a = Minimum { getMinimum :: Maybe a }

instance (Ord a) => Monoid (Minimum a) where
    mempty = Minimum Nothing
    mappend m1 (Minimum Nothing) = m1
    mappend (Minimum Nothing) m2 = m2
    mappend (Minimum (Just a1)) (Minimum (Just a2)) = Minimum (Just (min a1 a2))

minimumD
 :: (Monad m, ProxyP p)
 => x -> p x B.ByteString x B.ByteString (WriterT (Minimum Word8) m) r
minimumD = runIdentityK $ foreverK $ \x -> do
    bs <- request x
    lift $ tell $ Minimum $ Just $ B.minimum bs
    respond bs
-}

repeatS :: (Monad m, ProxyP p) => Word8 -> () -> Producer p B.ByteString m r
repeatS w8 () = runIdentityP $ forever $
    respond $ B.replicate defaultChunkSize w8

replicateS
 :: (Monad m, ProxyP p) => Int -> Word8 -> () -> Producer p B.ByteString m ()
replicateS n0 w8 () = runIdentityP (go n0) where
    go n
        | n < defaultChunkSize = respond (B.replicate n w8)
        | otherwise = do
            respond (B.replicate defaultChunkSize w8)
            go (n - defaultChunkSize)

cycleS
 :: (Monad m, ProxyP p) => B.ByteString -> () -> Producer p B.ByteString m r
cycleS bs () = runIdentityP $ forever $ do
    respond bs

iterateS
 :: (Monad m, ProxyP p)
 => (Word8 -> Word8) -> Word8 -> () -> Producer p B.ByteString m ()
iterateS f = unfoldrS (\x -> case f x of x' -> x' `seq` Just (x', x'))

unfoldrS
 :: (Monad m, ProxyP p)
 => (a -> Maybe (Word8, a)) -> a -> () -> Producer p B.ByteString m ()
unfoldrS f s0 () = runIdentityP $ unfoldChunk 32 s0 where
    unfoldChunk n s =
        case B.unfoldrN n f s of
            (c, Nothing)
                | B.null c  -> return ()
                | otherwise -> respond c
            (c, Just s') -> do
                respond c
                unfoldChunk (n * 2) s'

takeD :: (Monad m, ProxyP p) => Int -> x -> p x B.ByteString x B.ByteString m x
takeD n0 = runIdentityK (go n0) where
    go n
        | n <= 0 = return
        | otherwise = \x -> do
            bs <- request x
            let len = B.length bs
            if (len > n)
                then respond (BU.unsafeTake n bs)
                else do
                    x2 <- respond bs
                    go (n - len) x2

takeD_
 :: (Monad m, ProxyP p) => Int -> x -> p x B.ByteString x B.ByteString m ()
takeD_ n0 = runIdentityK (go n0) where
    go n
        | n <= 0 = \_ -> return ()
        | otherwise = \x -> do
            bs <- request x
            let len = B.length bs
            if (len > n)
                then do
                    respond (BU.unsafeTake n bs)
                    return ()
                else do
                    x2 <- respond bs
                    go (n - len) x2

dropD
 :: (Monad m, ProxyP p) => Int -> () -> Pipe p B.ByteString B.ByteString m r
dropD n0 () = runIdentityP (go n0) where
    go n
        | n <= 0 = idT ()
        | otherwise = do
            bs <- request ()
            let len = B.length bs
            if (len >= n)
                then do
                    respond (BU.unsafeDrop n bs)
                    idT ()
                else go (n - len)

takeWhileD
 :: (Monad m, ProxyP p)
 => (Word8 -> Bool) -> x -> p x B.ByteString x B.ByteString m ()
takeWhileD pred = runIdentityK go where
    go x = do
        bs <- request x
        case B.findIndex (not . pred) bs of
            Nothing -> do
                x2 <- respond bs
                go x2
            Just i -> do
                respond (BU.unsafeTake i bs)
                return ()

dropWhileD
 :: (Monad m, ProxyP p)
 => (Word8 -> Bool) -> () -> Pipe p B.ByteString B.ByteString m r
dropWhileD pred () = runIdentityP go where
    go = do
        bs <- request ()
        case B.findIndex (not . pred) bs of
            Nothing -> go
            Just i -> do
                respond (BU.unsafeDrop i bs)
                idT ()

-- groupS :: B.ByteString

hGetS :: (ProxyP p) => Int -> Handle -> () -> Producer p B.ByteString IO ()
hGetS size h () = runIdentityP go where
    go = do
        eof <- lift $ hIsEOF h
        if eof
            then return ()
            else do
                bs <- lift $ B.hGet h size
                respond bs
                go

hReadFileS :: (ProxyP p) => Handle -> () -> Producer p B.ByteString IO ()
hReadFileS = hGetS defaultChunkSize

hGetLineS :: (ProxyP p) => Handle -> () -> Producer p B.ByteString IO ()
hGetLineS h () = runIdentityP go where
    go = do
        eof <- lift $ hIsEOF h
        if eof
            then return ()
            else do
                bs <- lift $ B.hGetLine h
                respond bs
                go
