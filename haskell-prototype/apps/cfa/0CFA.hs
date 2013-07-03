{-# LANGUAGE TypeSynonymInstances, FlexibleInstances #-}

-- Translated from Matt Might's article: http://matt.might.net/articles/implementation-of-kcfa-and-0cfa/k-CFA.scm
-- Extended with less ad-hoc support for halting

import Control.Applicative (liftA2, liftA3)
import qualified Control.Monad.State as State
import Control.Monad

import qualified Data.Map as M
import qualified Data.Set as S
import Data.List ((\\))

import Debug.Trace

import Control.LVish
import  Data.LVar.Set as IS
import  Data.LVar.Map as IM

--------------------------------------------------------------------------------

type Var = String
type Label = Int
data Exp = Halt | Ref Var | Lam Label [Var] Call deriving (Eq, Ord, Show)
data Call = Call Label Exp [Exp] deriving (Eq, Ord, Show)

-- Abstract state space
data State = State Call BEnv Store Time
--           deriving (Eq, Ord, Show)
  deriving (Show, Eq)

-- A binding environment maps variables to addresses
-- (In Matt's example, this mapped to Addr, but I found this a bit redundant
-- since the Var in the Addr can be inferred, so I map straight to Time)
type BEnv = M.Map Var Time

-- A store maps addresses to denotable values
type Store = IM.IMap Addr Denotable

-- | An abstact denotable value is a set of possible values
type Denotable = IS.ISet Value

-- For pure CPS, closures are the only kind of value
type Value = Clo

-- Closures pair a lambda-term with a binding environment that determines
-- the values of its free variables
data Clo = Closure (Label, [Var], Call) BEnv | HaltClosure | Arbitrary
         deriving (Eq, Ord, Show)
-- Addresses can point to values in the store. In pure CPS, the only kind of addresses are bindings
type Addr = Bind

-- A binding is minted each time a variable gets bound to a value
data Bind = Binding Var Time
          deriving (Eq, Ord, Show)
-- In k-CFA, time is a bounded memory of program history.
-- In particular, it is the last k call sites through which
-- the program has traversed.
type Time = [Label]

instance Show Store where
  show _ = "<Store>"

-- State Call BEnv Store Time
instance Ord State where
  compare (State c1 be1 s1 t1)
          (State c2 be2 s2 t2)
    = compare c1 c2    `andthen`
      compare be1 be2  `andthen`
      compare t1 t2    `andthen`
      if s1 == s2
      then EQ
      else error "Ord State: states are equivalent except for Store... FINISHME"


andthen :: Ordering -> Ordering -> Ordering 
andthen EQ b = b
andthen a _  = a

--------------------------------------------------------------------------------

storeInsert :: Addr -> Value -> Store -> Par ()
storeInsert a v s = IM.modify a s (IS.putInSet v)
  
-- storeJoin :: Store -> Store -> Store
-- storeJoin = M.unionWith S.union

-- k-CFA parameters

k :: Int
k = 1

tick :: Label -> Time -> Time
tick l t = take k (l:t)

-- k-CFA abstract interpreter

atomEval :: BEnv -> Store -> Exp -> Par Denotable
atomEval benv store Halt    = single HaltClosure
atomEval benv store (Ref x) = case M.lookup x benv of
    Nothing -> error $ "Variable unbound in BEnv: " ++ show x
    Just t  -> IM.getKey (Binding x t) store 
--      case m of
--        Nothing -> error $ "Address unbound in Store: " -- ++ show (Binding x t)
--        Just d  -> return d
        
atomEval benv _  (Lam l v c) = single (Closure (l, v, c) benv)

single :: Ord a => a -> Par (ISet a)
single x = do 
  s <- newEmptySet  
  IS.putInSet x s
  return s


next :: State -> Par (S.Set State) -- Next states
next st0@(State (Call l fun args) benv store time)
  = trace ("next" ++ show st0) $ do
    procs   <- atomEval benv store fun
    paramss <- mapM (atomEval benv store) args

    -- Construct a graph of the state space as an adjacency map:
    graph <- newEmptyMap
    let time' = tick l time

    -- This applies to all elements evr added to the set object:
    IS.forEach procs $ \ clo -> do
      case clo of
        HaltClosure -> return ()
        
        Closure (_, formals, call') benv' -> do 
          let benv'' = foldr (\formal benv' -> M.insert formal time benv') benv' formals
          allParamConfs <- IS.cartesianProds paramss
          IS.forEach allParamConfs $ \ params -> do

            -- Hmm... we need to create a new store for the extended bindings
            store' <- IM.copy store
            let newST = State call' benv'' store' time'                
            forM_ (formals `zip` params) $ \(formal, params) ->
              storeInsert (Binding formal time) params store'
            
            IM.modify st0 graph (putInSet newST)
            return ()
          return ()

-- TODO: arbitrary:          
                     -- Arbitrary
                     --   -> [ state'
                     --      | params <- S.toList (transpose paramss)
                     --      , param <- params
                     --      , Just state' <- [escape param store]
                     --      ]

      return ()
    return undefined

storeJoin = undefined

-- Extension of my own design to allow CFA in the presence of arbitrary values.
-- Similar to "sub-0CFA" where locations are inferred to either have either a single
-- lambda flow to them, no lambdas, or all lambdas
escape :: Value -> Store -> Maybe State
escape Arbitrary                          _     = Nothing -- If an arbitrary value from outside escapes we don't care
escape HaltClosure                        _     = Nothing
escape (Closure (_l, formals, call) benv) store = Just (State call (benv `M.union` benv') (store `storeJoin` store') [])
  where (benv', store') = fvStuff formals

fvStuff :: [Var] -> (BEnv, Store)
fvStuff xs = (M.fromList [(x, []) | x <- xs],
--              M.fromList [(Binding x [], S.singleton Arbitrary) | x <- xs])
              error "FINISHME")

-- | Takes the cartesian product of several sets.
transpose :: Ord a => [IS.ISet a] -> Par (IS.ISet [a])
transpose = error "finish transpose"
-- transpose []         = S.singleton []
-- transpose (arg:args) = S.fromList [arg:args | args <- S.toList (transpose args), arg <- S.toList arg]

{-
-- State-space exploration

explore :: S.Set State -> [State] -> S.Set State
explore seen [] = seen
explore seen (todo:todos)
  | todo `S.member` seen = explore seen todos
  | otherwise            = explore (S.insert todo seen) (S.toList (next todo) ++ todos)
 -- NB: Might's dissertation (Section 5.3.5) explains how we can apply widening here to
 -- improve the worst case runtime from exponential to cubic: for an new state from the
 -- work list, we must extract all seen states which match in every element *except* the
 -- store. Then, join those seen stores together. If the potential store is a subset
 -- of the seen ones then we can just loop. Otherwise, union the new store onto a global
 -- "widening" store, update the global store with this one, and do abstract evalution on the state with the new sotre.

-- User interface

summarize :: S.Set State -> Store
summarize states = S.fold (\(State _ _ store' _) store -> store `storeJoin` store') M.empty states

-- ("Monovariant" because it throws away information we know about what time things arrive at)
monovariantStore :: Store -> M.Map Var (S.Set Exp)
monovariantStore store = M.foldrWithKey (\(Binding x _) d res -> M.alter (\mb_exp -> Just $ maybe id S.union mb_exp (S.map monovariantValue d)) x res) M.empty store

monovariantValue :: Value -> Exp
monovariantValue (Closure (l, v, c) _) = Lam l v c
monovariantValue HaltClosure           = Halt
monovariantValue Arbitrary             = Ref "unknown"

analyse :: Call -> M.Map Var (S.Set Exp)
analyse e = monovariantStore (summarize (explore S.empty [State e benv store []]))
  where (benv, store) = fvStuff (S.toList (fvsCall e))

fvsCall :: Call -> S.Set Var
fvsCall (Call _ fun args) = fvsExp fun `S.union` S.unions (map fvsExp args)

fvsExp :: Exp -> S.Set Var
fvsExp Halt         = S.empty
fvsExp (Ref x)      = S.singleton x
fvsExp (Lam _ xs c) = fvsCall c S.\\ S.fromList xs

-- Helper functions for constructing syntax trees

type UniqM = State.State Int

newLabel :: UniqM Int
newLabel = State.state (\i -> (i, i + 1))

runUniqM :: UniqM a -> a
runUniqM = fst . flip State.runState 0


ref :: Var -> UniqM Exp
ref = return . Ref

lam :: [Var] -> UniqM Call -> UniqM Exp
lam xs c = liftA2 (flip Lam xs) newLabel c

call :: UniqM Exp -> [UniqM Exp] -> UniqM Call
call e es = liftA3 Call newLabel e (sequence es)

let_ :: Var -> UniqM Exp -> UniqM Call -> UniqM Call
let_ x e c = call (lam [x] c) [e]

halt :: UniqM Exp -> UniqM Call
halt e = call (return Halt) [e]

-- The Standard Example
--
-- In direct style:
--
-- let id = \x -> x
--     a = id (\z -> halt z)
--     b = id (\y -> halt y)
-- in halt b
standardExample :: UniqM Call
standardExample = 
  let_ "id" (lam ["x", "k"] (call (ref "k") [ref "x"])) $
  call (ref "id") [lam ["z"] (halt (ref "z")),
                   lam ["a"] (call (ref "id") [lam ["y"] (halt (ref "y")),
                                               lam ["b"] (halt (ref "b"))])]

-- Example with free varibles (showing escapes):
fvExample :: UniqM Call
fvExample = 
  let_ "id" (lam ["x", "k"] (call (ref "k") [ref "x"])) $
  call (ref "id") [lam ["z"] (call (ref "escape") [ref "z"]),
                   lam ["a"] (call (ref "id") [lam ["y"] (call (ref "escape") [ref "y"]),
                                               lam ["b"] (call (ref "escape") [ref "b"])])]


main = forM_ [fvExample, standardExample] $ \example -> do
         putStrLn "====="
         forM_ (M.toList (analyse (runUniqM example))) $ \(x, es) -> do
           putStrLn (x ++ ":")
           mapM_ (putStrLn . ("  " ++) . show) (S.toList es)
-}

main = putStrLn "hi"

