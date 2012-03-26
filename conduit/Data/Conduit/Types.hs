{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE UndecidableInstances #-}
-- | Defines the types for a source, which is a producer of data.
module Data.Conduit.Types
    ( Source
    , Sink
    , Conduit
    , Pipe (..)
    , pipeClose
    , pipe
    , runPipe
    ) where

import Control.Applicative (Applicative (..), (<|>), (<$>))
import Control.Monad ((>=>), liftM)
import Control.Monad.Trans.Class (MonadTrans (lift))
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Base (MonadBase (liftBase))
import Data.Void (Void, absurd)

data Pipe i o m r =
    HaveOutput (Pipe i o m r) (m r) o
  | NeedInput (i -> Pipe i o m r) (Pipe () o m r)
  | Done (Maybe i) r
  | PipeM (m (Pipe i o m r)) (m r)

pipeClose :: Applicative m => Pipe i o m r -> m r
pipeClose (HaveOutput _ c _) = c
pipeClose (NeedInput _ p)= pipeClose p
pipeClose (Done _ r) = pure r
pipeClose (PipeM _ c) = c

noInput :: Functor m => Pipe i o m r -> Pipe () o m r
noInput (HaveOutput p r o) = HaveOutput (noInput p) r o
noInput (NeedInput _ c) = c
noInput (Done _ r) = Done Nothing r
noInput (PipeM mp c) = PipeM (noInput <$> mp) c

pipePush :: Functor m => i -> Pipe i o m r -> Pipe i o m r
pipePush i (HaveOutput p c o) = HaveOutput (pipePush i p) c o
pipePush i (NeedInput p c) = NeedInput (pipePush i . p) c
pipePush i (Done _ r) = Done (Just i) r
pipePush i (PipeM mp c) = PipeM (pipePush i <$> mp) c

type Source m a = Pipe () a m ()
type Sink i m o = Pipe i Void m o
type Conduit i m o = Pipe i o m ()

instance Functor m => Functor (Pipe i o m) where
    fmap f (HaveOutput p c o) = HaveOutput (f <$> p) (f <$> c) o
    fmap f (NeedInput p c) = NeedInput (fmap f . p) (f <$> c)
    fmap f (Done l r) = Done l (f r)
    fmap f (PipeM mp mr) = PipeM ((fmap f) <$> mp) (f <$> mr)

instance Applicative m => Applicative (Pipe i o m) where
    pure = Done Nothing

    Done il f <*> Done ir x = Done (il <|> ir) (f x)

    PipeM mp mr <*> right = PipeM
        ((<*> right) <$> mp)
        (mr <*> pipeClose right)
    HaveOutput p c o <*> right = HaveOutput
        (p <*> right)
        (c <*> pipeClose right)
        o
    NeedInput p c <*> right = NeedInput
        (\i -> p i <*> right)
        (c <*> noInput right)

    left@(Done _ f) <*> PipeM mp mr = PipeM
        ((left <*>) <$> mp)
        (f <$> mr)
    left@(Done _ f) <*> HaveOutput p c o = HaveOutput
        (left <*> p)
        (f <$> c)
        o
    left@(Done _ f) <*> NeedInput p c = NeedInput
        (\i -> left <*> p i)
        (f <$> c)

instance (Applicative m, Monad m) => Monad (Pipe i o m) where
    return = Done Nothing

    Done Nothing x >>= fp = fp x
    Done (Just i) x >>= fp = pipePush i $ fp x
    HaveOutput p c o >>= fp = HaveOutput (p >>= fp) (c >>= pipeClose . fp) o
    NeedInput p c >>= fp = NeedInput (p >=> fp) (c >>= noInput . fp)
    PipeM mp c >>= fp = PipeM ((>>= fp) <$> mp) (c >>= pipeClose . fp)

instance MonadBase base m => MonadBase base (Pipe i o m) where
    liftBase = lift . liftBase

instance MonadTrans (Pipe i o) where
    lift mr = PipeM (Done Nothing `liftM` mr) mr

instance (Applicative m, MonadIO m) => MonadIO (Pipe i o m) where
    liftIO = lift . liftIO

pipe :: (Applicative m, Monad m) => Pipe a b m () -> Pipe b c m r -> Pipe a c m r

-- Simplest case: both pipes are done. Discard the right pipe's leftovers.
pipe (Done l ()) (Done _discard r) = Done l r

-- Left pipe needs to run a monadic action.
pipe (PipeM mp c) right = PipeM
    ((`pipe` right) <$> mp)
    (c >> pipeClose right)

-- Left pipe needs more input, ask for it.
pipe (NeedInput p c) right = NeedInput
    (\a -> pipe (p a) right)
    (pipe c right)

-- Left pipe has output, right pipe wants it.
pipe (HaveOutput lp _ a) (NeedInput rp _) = pipe lp (rp a)

-- Right pipe needs to run a monadic action.
pipe left (PipeM mp c) = PipeM
    (pipe left <$> mp)
    (pipeClose left >> c)

-- Right pipe has some output, provide it downstream and continue.
pipe left (HaveOutput p c o) = HaveOutput
    (pipe left p)
    (pipeClose left >> c)
    o

-- Left pipe is done, right pipe needs input. In such a case, tell the right
-- pipe there is no more input, and eventually replace its leftovers with the
-- left pipe's leftover.
pipe (Done l ()) (NeedInput _ c) = replaceLeftover l c

-- Left pipe has more output, but right pipe doesn't want it.
pipe (HaveOutput _ c _) (Done _discard r) = PipeM
    (c >> return (Done Nothing r))
    (c >> return r)

replaceLeftover :: Functor m => Maybe i -> Pipe () o m r -> Pipe i o m r
replaceLeftover l (Done _ r) = Done l r
replaceLeftover l (HaveOutput p c o) = HaveOutput (replaceLeftover l p) c o

-- This function is only called on pipes when there is no more input available.
-- Therefore, we can ignore the push record.
replaceLeftover l (NeedInput _ c) = replaceLeftover l c

replaceLeftover l (PipeM mp c) = PipeM (replaceLeftover l <$> mp) c

runPipe :: Monad m => Pipe () Void m r -> m r
runPipe (HaveOutput _ _ o) = absurd o
runPipe (NeedInput p _) = runPipe (p ())
runPipe (Done _discard r) = return r
runPipe (PipeM mp _) = mp >>= runPipe