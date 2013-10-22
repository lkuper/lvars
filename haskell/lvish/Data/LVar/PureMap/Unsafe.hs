{-# LANGUAGE Unsafe #-}

{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeFamilies #-}

module Data.LVar.PureMap.Unsafe
       (
         -- * Unsafe operations:
         
         -- * These are here only to reexport downstream:
         IMap(..), forEachHP
       )
       where

import           Control.LVish.DeepFrz.Internal
import           Control.LVish
import           Control.LVish.Internal as LI
import           Control.LVish.SchedIdempotent (freezeLV)
import qualified Control.LVish.SchedIdempotent as L
import           Data.LVar.Generic as G
import           Data.LVar.Generic.Internal (unsafeCoerceLVar)
import           Data.UtilInternal (traverseWithKey_)

import           Control.Applicative ((<$>))
import           Data.IORef
import qualified Data.Foldable as F
import qualified Data.Map.Strict as M
import           Data.List (intersperse)
import           System.IO.Unsafe (unsafeDupablePerformIO)


------------------------------------------------------------------------------
-- IMaps implemented on top of LVars:
------------------------------------------------------------------------------

-- | The map datatype itself.  Like all other LVars, it has an @s@ parameter (think
--  `STRef`) in addition to the @a@ parameter that describes the type of elements
-- in the set.
-- 
-- Performance note: There is only /one/ mutable location in this implementation.  Thus
-- it is not a scalable implementation.
newtype IMap k s v = IMap (LVar s (IORef (M.Map k v)) (k,v))

-- | Equality is physical equality, as with @IORef@s.
instance Eq (IMap k s v) where
  IMap lv1 == IMap lv2 = state lv1 == state lv2 

-- | An `IMap` can be treated as a generic container LVar.  However, the polymorphic
-- operations are less useful than the monomorphic ones exposed by this module.
instance LVarData1 (IMap k) where
  freeze orig@(IMap (WrapLVar lv)) = WrapPar$ do freezeLV lv; return (unsafeCoerceLVar orig)
  -- Unlike the Map-specific forEach variants, this takes only values, not keys.
  addHandler mh mp fn = forEachHP mh mp (\ _k v -> fn v)
  sortFrzn (IMap lv) = AFoldable$ unsafeDupablePerformIO (readIORef (state lv))

-- | The `IMap`s in this module also have the special property that they support an
-- /O(1)/ freeze operation which immediately yields a `Foldable` container
-- (`snapFreeze`).
instance OrderedLVarData1 (IMap k) where
  snapFreeze is = unsafeCoerceLVar <$> freeze is

-- As with all LVars, after freezing, map elements can be consumed. In
-- the case of this `IMap` implementation, it need only be `Frzn`, not
-- `Trvrsbl`.
instance F.Foldable (IMap k Frzn) where
  foldr fn zer (IMap lv) =
    let set = unsafeDupablePerformIO (readIORef (state lv)) in
    F.foldr fn zer set 

-- Of course, the stronger `Trvrsbl` state is still fine for folding.
instance F.Foldable (IMap k Trvrsbl) where
  foldr fn zer mp = F.foldr fn zer (castFrzn mp)

-- `IMap` values can be returned as the result of a
--  `runParThenFreeze`.  Hence they need a `DeepFrz` instance.
--  @DeepFrz@ is just a type-coercion.  No bits flipped at runtime.
instance DeepFrz a => DeepFrz (IMap k s a) where
  type FrzType (IMap k s a) = IMap k Frzn (FrzType a)
  frz = unsafeCoerceLVar

instance (Show k, Show a) => Show (IMap k Frzn a) where
  show (IMap lv) =
    let mp' = unsafeDupablePerformIO (readIORef (state lv)) in
    "{IMap: " ++
    (concat $ intersperse ", " $ map show $
     M.toList mp') ++ "}"

-- | For convenience only; the user could define this.
instance (Show k, Show a) => Show (IMap k Trvrsbl a) where
  show lv = show (castFrzn lv)


-- | Add an (asynchronous) callback that listens for all new key/value pairs added to
-- the map, optionally enrolled in a handler pool.
forEachHP :: Maybe HandlerPool           -- ^ optional pool to enroll in 
          -> IMap k s v                  -- ^ Map to listen to
          -> (k -> v -> Par d s ())      -- ^ callback
          -> Par d s ()
forEachHP mh (IMap (WrapLVar lv)) callb = WrapPar $ do
    L.addHandler mh lv globalCB deltaCB
    return ()
  where
    deltaCB (k,v) = return$ Just$ unWrapPar $ callb k v
    globalCB ref = do
      mp <- readIORef ref -- Snapshot
      return $ Just $ unWrapPar $ 
        traverseWithKey_ (\ k v -> forkHP mh$ callb k v) mp

------------------------------------------------------------------------------

