{-# LANGUAGE CPP #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE MultiParamTypeClasses #-}
--------------------------------------------------------------------
-- |
-- Copyright :  (c) Edward Kmett 2011-2012
-- License   :  BSD3
-- Maintainer:  Edward Kmett <ekmett@gmail.com>
-- Stability :  experimental
-- Portability: non-portable
--
--------------------------------------------------------------------
module Ermine.Inference.Kind
  ( inferKind
  , inferAnnotKind
  , checkKind
  , checkDataTypeKinds
  , checkDataTypeGroup
  , checkDataTypeKind
  , checkConstructorKind
  ) where

import Bound
import Bound.Var
import Control.Applicative
import Control.Comonad
import Control.Lens
import Control.Monad
import Control.Monad.State
import Data.Foldable hiding (concat)
import Data.Graph (stronglyConnComp, flattenSCC)
import Data.List (nub, elemIndex, (\\))
import qualified Data.Map as Map
import Data.Map (Map)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Traversable (for)
import Data.Void
import Ermine.Diagnostic
import Ermine.Syntax.Constructor as Data
import Ermine.Syntax.Data as Data
import Ermine.Syntax.Global
import Ermine.Syntax.Kind as Kind
import Ermine.Syntax.Name
import Ermine.Syntax.Scope
import qualified Ermine.Syntax.Type as Type
import Ermine.Syntax.Type hiding (Var)
import Ermine.Unification.Data
import Ermine.Unification.Kind
import Ermine.Unification.Meta
import Ermine.Unification.Sharing

productKind :: Int -> Kind k
productKind 0 = star
productKind n = star :-> productKind (n - 1)

matchFunKind :: MonadMeta s m => KindM s -> m (KindM s, KindM s)
matchFunKind (a :-> b)    = return (a, b)
matchFunKind (Var kv) = do
  a <- Var <$> newMeta False Nothing
  b <- Var <$> newMeta False Nothing
  (a, b) <$ unsharingT (unifyKindVar kv (a :-> b))
matchFunKind (Type _)     = fail "not a fun kind"
matchFunKind (HardKind _) = fail "not a fun kind"

instantiateSchema :: MonadMeta s m => Schema (MetaK s) -> m (KindM s)
instantiateSchema (Schema hs s) = do
  vs <- forM hs (fmap Var . newMeta False)
  return $ instantiate (vs!!) s
{-# INLINE instantiateSchema #-}

-- | Check that the 'Kind' of a given 'Type' can unify with the specified kind.
checkKind :: MonadMeta s m => Type (MetaK s) (KindM s) -> KindM s -> m ()
checkKind t k = do
  k' <- inferKind t
  () <$ unsharingT (unifyKind k k')

-- | Infer a kind for a given type.
inferKind :: MonadMeta s m => Type (MetaK s) (KindM s) -> m (KindM s)
inferKind (Loc l t)                = set rendering l `localMeta` inferKind t
inferKind (Type.Var tk)            = return tk
inferKind (HardType Arrow)         = do
  a <- Var <$> newMeta True Nothing
  b <- Var <$> newMeta True Nothing
  return $ Type a :-> Type b :-> star
inferKind (HardType (Con _ s))     = instantiateSchema (vacuous s)
inferKind (HardType (Tuple n))     = return $ productKind n
inferKind (HardType ConcreteRho{}) = return rho
inferKind (App f x) = do
  kf <- inferKind f
  (a, b) <- matchFunKind kf
  b <$ checkKind x a
inferKind (And cs) = constraint <$ traverse_ (checkKind ?? constraint) cs
inferKind (Exists n tks cs) = do
  sks <- for n $ newMeta False
  let btys = instantiateVars sks . extract <$> tks
  checkKind (instantiateKindVars sks $ instantiateVars btys cs) constraint
  -- TODO: check mutually exclusive sks?
  return constraint
inferKind (Forall n tks cs b) = do
  sks <- for n $ newMeta False
  let btys = instantiateVars sks . extract <$> tks
  checkKind (instantiateKindVars sks (instantiateVars btys cs)) constraint
  checkKind (instantiateKindVars sks (instantiateVars btys b)) star
  -- TODO: check mutually exclusive sks?
  return star

inferAnnotKind :: MonadMeta s m => Annot (KindM s) -> m (KindM s)
inferAnnotKind (Annot hs hts ty) = do
  ks <- for hs $ newMeta False
  ts <- for hts $ fmap pure . newMeta False
  inferKind . over kindVars (ks!!) $ instantiateVars ts ty

fixCons :: (Ord t) => Map t (Type k u) -> (t -> Type k u) -> DataType k t -> DataType k u
fixCons m f = boundBy (\t -> fromMaybe (f t) $ Map.lookup t m)

-- | Checks a list of data types for well-kindedness. The unit in the kind
-- variables is interpreted as an unknown, which must be determined by the
-- algorithm. The string variables may refer to other data types in the
-- group. During the process, all unknowns will be solved or generalized,
-- and all type variables will be replaced by the respective constructor
-- with the appropriate schematic type. These are returned from the
-- procedure.
--
-- TODO: Currently, the following example fails with a skolem escape:
--
-- @
--   data Foo (a : k) = Foo (Bar a)
--   data Bar a = Bar (Foo a)
-- @
--
-- This is because Foo and Bar must be checked as a group, k is skolemized
-- for the checking of Foo, but its type leaks to Bar's unknown kind.
-- Resolving this may be complicated, as it requires a similar
-- explicit/implicit divide as checking lets, but partial annotations are
-- possible. One solution may be to infer first and then check against
-- annotations. Kind checking is Hindley-Milner, so this is viable.
checkDataTypeKinds :: [DataType () Text] -> M s [DataType Void Void]
checkDataTypeKinds dts = flip evalStateT Map.empty
                       . fmap concat . traverse (ck.flattenSCC) $ stronglyConnComp graph
 where
 graph = map (\dt -> (dt, dt^.name, toListOf typeVars dt)) dts
 conMap = Map.fromList . map (\dt -> (dt^.name, con (dt^.global) (dataTypeSchema dt)))
 ck scc = StateT $ \m -> do
   let scc' = map (fixCons m pure) scc
   cscc <- checkDataTypeGroup scc'
   return (cscc, m `Map.union` conMap cscc)

checkDataTypeGroup :: [DataType () Text] -> M s [DataType Void Void]
checkDataTypeGroup dts = do
  dts' <- traverse (kindVars (\_ -> newMeta False Nothing)) dts
  let m = Map.fromList $ map (\dt -> (dt^.name, dt)) dts'
  checked <- for dts' $ \dt -> (dt,) <$> checkDataTypeKind m dt
  let sm = Map.fromList $ (\(dt, (_, sch)) -> (dt^.name, con (dt^.global) sch)) <$> checked
      sdts = checked <&> \(dt, (sks, _)) ->
               (sks, fixCons sm (\_ -> error "checkDataTypeGroup: IMPOSSIBLE") dt)
  traverse closeKinds sdts
 where
 closeKinds (sks0, dt) = do
   sks <- checkDistinct sks0
   dt' <- zonkDataType dt
   let fvs = (\\sks) . nub . toListOf kindVars $ dt'
       offset = length sks
       f (F m) | Just i <- m `elemIndex` fvs = pure . B $ i + offset
               | Just i <- m `elemIndex` sks = pure . B $ i
               | otherwise                   = fail "escaped skolem"
       f (B i)                               = pure $ B i
       reabstr = fmap toScope . traverse f . fromScope
   ts' <- (traverse . traverse) reabstr $ dt'^.tparams
   cs' <- (traverse . kindVars) f $ dt'^.constrs
   return $ DataType (dt^.global) (dt^.kparams ++ (Nothing <$ fvs)) ts' cs'

-- | Checks that the types in a data declaration have sensible kinds.
checkDataTypeKind :: Map Text (DataType (MetaK s) a) -> DataType (MetaK s) Text
                  -> M s ([MetaK s], Schema v)
checkDataTypeKind m dt = do
  sks <- for (dt^.kparams) $ newMeta False
  let Schema _ s = dataTypeSchema dt
      selfKind = instantiateVars sks s
  dt' <- for dt $ \t ->
           if t == dt^.name
             then pure selfKind
             else case Map.lookup t m of
               Just sc -> refresh (dataTypeSchema sc)
               Nothing -> fail "unknown reference"
  let btys = instantiateVars sks . extract <$> (dt^.tparams)
  for_ (dt'^.constrs) $ \c ->
    checkConstructorKind $ bimap (unvar (sks!!) id) (unvar (btys !!) id) c
  void $ checkDistinct sks
  (sks,) <$> generalize selfKind
  -- TODO: check that sks is mutually exclusive
 where
 refresh (Schema ks s) =
   (instantiateVars ?? s) <$> traverse (newMeta False) ks

-- | Checks that the types in a data constructor have sensible kinds.
checkConstructorKind :: Constructor (MetaK s) (KindM s) -> M s ()
checkConstructorKind (Constructor _ ks ts fs) = do
  sks <- for ks $ newMeta False
  let btys = instantiateVars sks . extract <$> ts
  for_ fs $ \fld ->
    checkKind (instantiateKindVars sks $ instantiateVars btys fld) star
  () <$ checkDistinct sks
