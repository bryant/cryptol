-- |
-- Module      :  $Header$
-- Copyright   :  (c) 2013-2015 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com
-- Stability   :  provisional
-- Portability :  portable

{-# LANGUAGE Safe #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE PatternGuards #-}
module Cryptol.TypeCheck.Solver.CrySAT
  ( withScope, withSolver
  , assumeProps, simplifyProps, getModel
  , check
  , Solver, logger
  , DefinedProp(..)
  , debugBlock
  , DebugLog(..)
  , prepareConstraints
  ) where

import qualified Cryptol.TypeCheck.AST as Cry
import           Cryptol.TypeCheck.PP(pp)
import           Cryptol.TypeCheck.InferTypes(Goal(..), SolverConfig(..))
import qualified Cryptol.TypeCheck.Subst as Cry

import           Cryptol.TypeCheck.Solver.Numeric.AST
import           Cryptol.TypeCheck.Solver.Numeric.ImportExport
import           Cryptol.TypeCheck.Solver.Numeric.Defined
import           Cryptol.TypeCheck.Solver.Numeric.Simplify
import           Cryptol.TypeCheck.Solver.Numeric.NonLin
import           Cryptol.TypeCheck.Solver.Numeric.SMT
import           Cryptol.Utils.Panic ( panic )

import           MonadLib
import           Data.Maybe ( mapMaybe, fromMaybe )
import           Data.Either ( partitionEithers )
import           Data.List(nub)
import qualified Data.Map as Map
import           Data.Foldable ( any, all )
import           Data.Set ( Set )
import qualified Data.Set as Set
import           Data.IORef ( IORef, newIORef, readIORef, modifyIORef',
                              atomicModifyIORef' )
import           Prelude hiding (any,all)

import qualified SimpleSMT as SMT
import           Text.PrettyPrint(Doc)


-- | We use this to remember what we simplified
newtype SimpProp = SimpProp Prop

simpProp :: Prop -> SimpProp
simpProp p = SimpProp (crySimplify p)


-- | 'dpSimpProp' and 'dpSimpExprProp' should be logically equivalent,
-- to each other, and to whatever 'a' represents (usually 'a' is a 'Goal').
data DefinedProp a = DefinedProp
  { dpData         :: a
    -- ^ Optional data to associate with prop.
    -- Often, the original `Goal` from which the prop was extracted.

  , dpSimpProp     :: SimpProp
    {- ^ Fully simplified: may mention ORs, and named non-linear terms.
    These are what we send to the prover, and we don't attempt to
    convert them back into Cryptol types. -}

  , dpSimpExprProp :: Prop
    {- ^ A version of the proposition where just the expression terms
    have been simplified.  These should not contain ORs or named non-linear
    terms because we want to import them back into Crytpol types. -}
  }


instance HasVars SimpProp where
  apSubst su (SimpProp p) = do p1 <- apSubst su p
                               let p2 = crySimplify p1
                               guard (p1 /= p2)
                               return (SimpProp p2)

apSubstDefinedProp :: (Prop -> a -> a) ->
                      Subst -> DefinedProp a -> Maybe (DefinedProp a)
apSubstDefinedProp updCt su DefinedProp { .. } =
  do s1 <- apSubst su dpSimpProp
     return $ case apSubst su dpSimpExprProp of
                Nothing -> DefinedProp { dpSimpProp = s1, .. }
                Just p1 -> DefinedProp { dpSimpProp = s1
                                       , dpSimpExprProp = p1
                                       , dpData = updCt p1 dpData
                                       }



{- | Check if the given constraint is guaranteed to be well-defined.
This means that it cannot be instantiated in a way that would result in
undefined behaviour.

This estimate is consevative:
  * if we return `Right`, then the property is definately well-defined
  * if we return `Left`, then we don't know if the property is well-defined

If the property is well-defined, then we also simplify it.
-}
checkDefined1 :: Solver -> (Prop -> a -> a) ->
                (a,Prop) -> IO (Either (a,Prop) (DefinedProp a))
checkDefined1 s updCt (ct,p) =
  do proved <- prove s defCt
     return $
       if proved
         then Right $
                case crySimpPropExprMaybe p of
                  Nothing -> DefinedProp { dpData         = ct
                                         , dpSimpExprProp = p
                                         , dpSimpProp     = simpProp p
                                         }
                  Just p' -> DefinedProp { dpData         = updCt p' ct
                                         , dpSimpExprProp = p'
                                         , dpSimpProp     = simpProp p'
                                         }
         else Left (ct,p)
  where
  SimpProp defCt = simpProp (cryDefinedProp p)



prepareConstraints ::
  Solver -> (Prop -> a -> a) -> Set Name ->
  [(a,Prop)] -> IO (Either [a] ([a], [DefinedProp a], Subst, [Prop]))
prepareConstraints s updCt uniVars cs =
  do res <- mapM (checkDefined1 s updCt) cs
     let (unknown,ok) = partitionEithers res
     goStep1 unknown ok Map.empty []


  where
  getImps ok = withScope s $
               do mapM_ (assert s . dpSimpProp) ok
                  check s uniVars

  mapEither f = partitionEithers . map f

  apSuUnk su (x,p) =
    case apSubst su p of
      Nothing -> Left (x,p)
      Just p1 -> Right (updCt p1 x, p1)

  apSuOk su p = case apSubstDefinedProp updCt su p of
                  Nothing -> Left p
                  Just p1 -> Right p1

  apSubst' su x = fromMaybe x (apSubst su x)

  goStep1 unknown ok su sgs =
    let (ok1, moreSu) = improveByDefnMany updCt uniVars ok
    in go unknown ok1 (composeSubst moreSu su) sgs

  go unknown ok su sgs =
    do mb <- getImps ok
       case mb of
         Nothing ->
           do bad <- minimizeContradictionSimpDef s ok
              return (Left bad)
         Just (imps,subGoals)
           | not (null okNew) -> goStep1 unknown (okNew ++ okOld) newSu newGs
           | otherwise ->
             do res <- mapM (checkDefined1 s updCt) unkNew
                let (stillUnk,nowOk) = partitionEithers res
                if null nowOk
                  then return (Right ( map fst (unkNew ++ unkOld)
                                     , ok, newSu, newGs))
                  else goStep1 (stillUnk ++ unkOld) (nowOk ++ ok) newSu newGs

           where (okOld, okNew)  = mapEither (apSuOk  imps) ok
                 (unkOld,unkNew) = mapEither (apSuUnk imps) unknown
                 newSu = composeSubst imps su
                 newGs = nub (subGoals ++ map (apSubst' su) sgs)
                                          -- XXX: inefficient





-- | Simplify a bunch of well-defined properties.
--  * Eliminates properties that are implied by the rest.
--  * Does not modify the set of assumptions.
simplifyProps :: Solver -> [DefinedProp a] -> IO [a]
simplifyProps s props =
  debugBlock s "Simplifying properties" $
  withScope s (go [] props)
  where
  go survived [] = return survived

  go survived (DefinedProp { dpSimpProp = SimpProp PTrue } : more) =
                                                          go survived more

  go survived (p : more) =
    case dpSimpProp p of
      SimpProp PTrue -> go survived more
      SimpProp p' ->
        do proved <- withScope s $ do mapM_ (assert s . dpSimpProp) more
                                      prove s p'
           if proved
             then go survived more
             else do assert s (SimpProp p')
                     go (dpData p : survived) more


-- | Add the given constraints as assumptions.
--  * We assume that the constraints are well-defined.
--  * Modifies the set of assumptions.
assumeProps :: Solver -> [Cry.Prop] -> IO VarMap
assumeProps s props = fmap fst (assumeProps' s props)


-- | Add the given constraints as assumptions.
--  * We assume that the constraints are well-defined.
--  * Modifies the set of assumptions.
assumeProps' :: Solver -> [Cry.Prop] -> IO (VarMap, [SimpProp])
assumeProps' s props =
  do let simpProps = map simpProp (map cryDefinedProp ps ++ ps)
     mapM_ (assert s) simpProps
     return (Map.unions varMaps, simpProps)
  where (ps,varMaps) = unzip (mapMaybe exportProp props)
  -- XXX: Instead of asserting one at a time, perhaps we should
  -- assert a conjunction.  That way, we could simplify the whole thing
  -- in one go, and would avoid having to assert 'true' many times.




-- | Given a list of propositions that together lead to a contradiction,
-- find a sub-set that still leads to a contradiction (but is smaller).
minimizeContradictionSimpDef :: Solver -> [DefinedProp a] -> IO [a]
minimizeContradictionSimpDef s ps = start [] ps
  where
  start bad todo =
    do res <- SMT.check (solver s)
       case res of
         SMT.Unsat -> return (map dpData bad)
         _         -> do solPush s
                         go bad [] todo

  go _ _ [] = panic "minimizeContradiction"
               $ ("No contradiction" : map (show . ppProp . dpSimpExprProp) ps)
  go bad prev (d : more) =
    do assert s (dpSimpProp d)
       res <- SMT.check (solver s)
       case res of
         SMT.Unsat -> do solPop s
                         assert s (dpSimpProp d)
                         start (d : bad) prev
         _ -> go bad (d : prev) more


improveByDefnMany :: (Prop -> a -> a) -> Set Name ->
                    [DefinedProp a] -> ([DefinedProp a], Subst)
improveByDefnMany updCt uvs = go [] Map.empty
  where
  mbSu su x = case apSubstDefinedProp updCt su x of
                Nothing -> Left x
                Just y  -> Right y

  go todo su (p : ps) =
    let p1 = fromMaybe p (apSubstDefinedProp updCt su p)
    in case improveByDefn uvs p1 of
         Just (x,e) -> go todo (Map.insert x e su) ps
                      -- `p` is solved, so ignore
         Nothing    -> go (p1 : todo) su ps

  go todo su [] =
    let (same,changed) = partitionEithers (map (mbSu su) todo)
    in case changed of
         [] -> (same,su)
         _  -> go same su changed


{- | If we see an equation: `?x = e`, and:
      * ?x is a unification variable
      * `e` is "zonked" (substitution is fully applied)
      * ?x does not appear in `e`.
    then, we can improve `?x` to `e`.
-}
improveByDefn :: Set Name -> DefinedProp a -> Maybe (Name,Expr)
improveByDefn uvs p =
  case dpSimpExprProp p of
    Var x :== e
      | x `Set.member` uvs -> tryToBind x e
    e :== Var x
      | x `Set.member` uvs -> tryToBind x e
    _ -> Nothing

  where
  tryToBind x e
    | x `Set.member` cryExprFVS e = Nothing
    | otherwise                   = Just (x,e)


{- | Attempt to find a substituion that, when applied, makes all of the
given properties hold. -}
getModel :: Solver -> [Cry.Prop] -> IO (Maybe Cry.Subst)
getModel s props = withScope s $
  do (varMap,ps) <- assumeProps' s props
     res         <- SMT.check (solver s)

     case res of
       SMT.Sat ->
          do vs <- getVals (solver s) (Map.keys varMap)
             -- This is guaranteed to be a model only for the *linear*
             -- properties, so now we check if it works for the rest too.

             let su1  = fmap K vs
                 ps1  = [ fromMaybe p (apSubst su1 p) | SimpProp p <- ps ]
                 ok p = case crySimplify p of
                          PTrue -> True
                          _     -> False

                 su2 = Cry.listSubst
                     $ Map.elems
                     $ Map.intersectionWith (,) varMap (fmap numTy vs)

             return (guard (all ok ps1) >> return su2)


       _ -> return Nothing


  where
  numTy Inf     = Cry.tInf
  numTy (Nat k) = Cry.tNum k

--------------------------------------------------------------------------------


-- | An SMT solver, and some info about declared variables.
data Solver = Solver
  { solver    :: SMT.Solver
    -- ^ The actual solver

  , declared  :: IORef VarInfo
    -- ^ Information about declared variables, and assumptions in scope.

  , logger    :: SMT.Logger
    -- ^ For debugging
  }


-- | Keeps track of declared variables and non-linear terms.
data VarInfo = VarInfo
  { curScope    :: Scope
  , otherScopes :: [Scope]
  } deriving Show

data Scope = Scope
  { scopeNames    :: [Name]
    -- ^ Variables declared in this scope (not counting the ones from
    -- previous scopes).

  , scopeMarked   :: Set Name
    {- ^ These are not interesting names.  This is used when we apply
    a substitution to the non-linear terms. Example:
    Consider a NL term:  x :=  a * b
    We apply the su. { a := 5 }.
    As a result, `x` becomes linear: 5 * b, so we remove from the NonLinS.
    However, the variable `x` may be still mentioned in other assertions.
    So, we add a new assertion `x = 5 * b`.  All done!  From now on, though,
    we don't want to ever have to deal with `x` in any models: it really is
    just a left-over from the old NL term.  We implement this by "marking"
    `x`, and simply ignoring it when we compute models.
    -}

  , scopeNonLinS  :: NonLinS
    {- ^ These are the non-linear terms mentioned in the assertions
    that are currently asserted (including ones from previous scopes). -}

  } deriving Show

scopeEmpty :: Scope
scopeEmpty = Scope { scopeNames = []
                   , scopeMarked = Set.empty
                   , scopeNonLinS = initialNonLinS
                   }

scopeElem :: Name -> Scope -> Bool
scopeElem x Scope { .. } = x `elem` scopeNames

scopeInsert :: Name -> Scope -> Scope
scopeInsert x Scope { .. } = Scope { scopeNames = x : scopeNames, .. }

scopeLookupNL :: Name -> Scope -> Maybe Expr
scopeLookupNL x Scope { .. } = lookupNL x scopeNonLinS


-- | Given a *simplified* prop, separate linear and non-linear parts
-- and return the linear ones.
scopeAssert :: SimpProp -> Scope -> (SimpProp,Scope)
scopeAssert (SimpProp p) Scope { .. } =
  let (p1,s1) = nonLinProp scopeNonLinS p
  in (SimpProp p1, Scope { scopeNonLinS = s1, ..  })


-- | No scopes.
viEmpty :: VarInfo
viEmpty = VarInfo { curScope = scopeEmpty, otherScopes = [] }

-- | Check if a name is any of the scopes.
viElem :: Name -> VarInfo -> Bool
viElem x VarInfo { .. } = any (x `scopeElem`) (curScope : otherScopes)

-- | Add a name to a scope.
viInsert :: Name -> VarInfo -> VarInfo
viInsert x VarInfo { .. } = VarInfo { curScope = scopeInsert x curScope, .. }

-- | Add an assertion to the current scope. Returns the linear part.
viAssert :: SimpProp -> VarInfo -> (VarInfo, SimpProp)
viAssert p VarInfo { .. } = ( VarInfo { curScope = s1, .. }, p1)
  where (p1, s1) = scopeAssert p curScope

-- | Enter a scope.
viPush :: VarInfo -> VarInfo
viPush VarInfo { .. } =
  VarInfo { curScope = scopeEmpty { scopeNonLinS = scopeNonLinS curScope }
          , otherScopes = curScope : otherScopes
          }

-- | Exit a scope.
viPop :: VarInfo -> VarInfo
viPop VarInfo { .. } = case otherScopes of
                         c : cs -> VarInfo { curScope = c, otherScopes = cs }
                         _ -> panic "viPop" ["no more scopes"]


-- | All declared names, that have not been "marked".
-- These are the variables whose values we are interested in.
viUnmarkedNames :: VarInfo -> [ Name ]
viUnmarkedNames VarInfo { .. } = filter (not . isMarked)
                                                (concatMap scopeNames scopes)
  where
  allMarked   = Set.unions (map scopeMarked scopes)
  isMarked x  = x `Set.member` allMarked
  scopes      = curScope : otherScopes

viLookupNL :: Name -> VarInfo -> Maybe Expr
viLookupNL x VarInfo { .. } = scopeLookupNL x curScope


-- | Check if this is a non-linear var.  If so, returns its definition.
lookupNLVar :: Solver -> Name -> IO (Maybe Expr)
lookupNLVar Solver { .. } x = viLookupNL x `fmap` readIORef declared


-- | All known non-linear terms.
getNLSubst :: Solver -> IO Subst
getNLSubst Solver { .. } =
  do VarInfo { .. } <- readIORef declared
     return $ nonLinSubst $ scopeNonLinS curScope

-- | Execute a computation with a fresh solver instance.
withSolver :: SolverConfig -> (Solver -> IO a) -> IO a
withSolver SolverConfig { .. } k =
  do logger <- if solverVerbose > 0 then SMT.newLogger 0 else return quietLogger

     solver <- SMT.newSolver solverPath solverArgs Nothing --} (Just logger)
     _ <- SMT.setOptionMaybe solver ":global-decls" "false"
     SMT.setLogic solver "QF_LIA"
     declared <- newIORef viEmpty
     a <- k Solver { .. }
     _ <- SMT.stop solver

     return a

  where
  quietLogger = SMT.Logger { SMT.logMessage = \_ -> return ()
                           , SMT.logLevel   = return 0
                           , SMT.logSetLevel= \_ -> return ()
                           , SMT.logTab     = return ()
                           , SMT.logUntab   = return ()
                           }

solPush :: Solver -> IO ()
solPush Solver { .. } =
  do SMT.push solver
     SMT.logTab logger
     modifyIORef' declared viPush

solPop :: Solver -> IO ()
solPop Solver { .. } =
  do modifyIORef' declared viPop
     SMT.logUntab logger
     SMT.pop solver

-- | Execute a computation in a new solver scope.
withScope :: Solver -> IO a -> IO a
withScope s k =
  do solPush s
     a <- k
     solPop s
     return a

-- | Declare a variable.
declareVar :: Solver -> Name -> IO ()
declareVar s@Solver { .. } a =
  do done <- fmap (a `viElem`) (readIORef declared)
     unless done $
       do e  <- SMT.declare solver (smtName a)    SMT.tInt
          let fin_a = smtFinName a
          fin <- SMT.declare solver fin_a SMT.tBool
          SMT.assert solver (SMT.geq e (SMT.int 0))

          nlSu <- getNLSubst s
          modifyIORef' declared (viInsert a)
          case Map.lookup a nlSu of
            Nothing -> return ()
            Just e'  ->
              do let finDef = crySimplify (Fin e')
                 mapM_ (declareVar s) (Set.toList (cryPropFVS finDef))
                 SMT.assert solver $
                    SMT.eq fin (ifPropToSmtLib (desugarProp finDef))



-- | Add an assertion to the current context.
-- INVARIANT: Assertion is simplified.
assert :: Solver -> SimpProp -> IO ()
assert _ (SimpProp PTrue) = return ()
assert s@Solver { .. } p@(SimpProp p0) =
  do debugLog s ("Assuming: " ++ show (ppProp p0))
     SimpProp p1 <- atomicModifyIORef' declared (viAssert p)
     mapM_ (declareVar s) (Set.toList (cryPropFVS p1))
     SMT.assert solver $ ifPropToSmtLib $ desugarProp p1


-- | Try to prove a property.  The result is 'True' when we are sure that
-- the property holds, and 'False' otherwise.  In other words, getting `False`
-- *does not* mean that the proposition does not hold.
prove :: Solver -> Prop -> IO Bool
prove _ PTrue = return True
prove s@(Solver { .. }) p =
  debugBlock s ("Proving: " ++ show (ppProp p)) $
  withScope s $
  do assert s (simpProp (Not p))
     res <- SMT.check solver
     case res of
       SMT.Unsat   -> debugLog s "Proved" >> return True
       SMT.Unknown -> debugLog s "Not proved" >> return False -- We are not sure
       SMT.Sat     -> debugLog s "Not proved" >> return False
        -- XXX: If the answer is Sat, it is possible that this is a
        -- a fake example, as we need to evaluate the nonLinear constraints.
        -- If they are all satisfied, then we have a genuine counter example.
        -- Otherwise, we could look for another one...


{- | Check if the current set of assumptions is satisfiable, and find
some facts that must hold in any models of the current assumptions.

Returns `Nothing` if the currently asserted constraints are known to
be unsatisfiable.

Returns `Just (su, sub-goals)` is the current set is satisfiable.
  * The `su` is a substitution that may be applied to the current constraint
    set without loosing generality.
  * The `sub-goals` are additional constraints that must hold if the
    constraint set is to be satisfiable.
-}
check :: Solver -> Set Name -> IO (Maybe (Subst, [Prop]))
check s@Solver { .. } uniVars =
  do res <- SMT.check solver
     case res of

       SMT.Unsat   ->
        do debugLog s "Not satisfiable"
           return Nothing

       SMT.Unknown ->
        do debugLog s "Unknown"
           return (Just (Map.empty, []))

       SMT.Sat     ->
        do debugLog s "Satisfiable"
           (impMap,sideConds) <- debugBlock s "Computing improvements"
                                     (getImpSubst s uniVars)
           return (Just (impMap, sideConds))



{- | The set of unification variables is used to guide ordering of
assignments (we prefer assigning to them, as that amounts to doing
type inference).

Returns an improving substitution, which (in principle) may mention
the names of non-linear terms.
XXX: At the moment we discard such improvements.
-}
getImpSubst :: Solver -> Set Name -> IO (Subst,[Prop])
getImpSubst s@Solver { .. } uniVars =
  do names <- viUnmarkedNames `fmap` readIORef declared
     m     <- getVals solver names
     (impSu,sideConditions)
           <- cryImproveModel solver logger uniVars m

     let isNonLinName (SysName {})  = True
         isNonLinName (UserName {}) = False


         keep k e = not (isNonLinName k) &&
                    all (not . isNonLinName) (cryExprFVS e)

         (easy,tricky) = Map.partitionWithKey keep impSu
         dump (x,e) = debugLog s (show (ppProp (Var x :== e)))

     debugBlock s "side conditions:" $
         mapM_ (debugLog s . show . ppProp) sideConditions

     when (not (Map.null tricky)) $
       debugBlock s "Tricky subst:" $ mapM_ dump (Map.toList tricky)

     if Map.null easy
        then debugLog s "(no improvements)"
        else mapM_ dump (Map.toList easy)

     scs <- mapM importSideCond sideConditions

     return (easy,scs)


  where
  importSideCond expr =
    case expr of
      e1 :>= e2 -> do e1' <- impNL e1
                      e2' <- impNL e2
                      return (e1' :>= e2')
      _ -> panic "importSideCond" [ "Unexpected side condition:", show expr ]

  impNL e =
    case e of
      Var x -> do mb <- lookupNLVar s x
                  case mb of
                    Just e1 -> return e1
                    Nothing -> return e
      _ -> return e






--------------------------------------------------------------------------------

debugBlock :: Solver -> String -> IO a -> IO a
debugBlock s@Solver { .. } name m =
  do debugLog s name
     SMT.logTab logger
     a <- m
     SMT.logUntab logger
     return a

class DebugLog t where
  debugLog :: Solver -> t -> IO ()

  debugLogList :: Solver -> [t] -> IO ()
  debugLogList s ts = case ts of
                        [] -> debugLog s "(none)"
                        _  -> mapM_ (debugLog s) ts

instance DebugLog Char where
  debugLog s x     = SMT.logMessage (logger s) (show x)
  debugLogList s x = SMT.logMessage (logger s) x

instance DebugLog a => DebugLog [a] where
  debugLog = debugLogList

instance DebugLog a => DebugLog (Maybe a) where
  debugLog s x = case x of
                   Nothing -> debugLog s "(nothing)"
                   Just a  -> debugLog s a

instance DebugLog Doc where
  debugLog s x = debugLog s (show x)

instance DebugLog Cry.Type where
  debugLog s x = debugLog s (pp x)

instance DebugLog Goal where
  debugLog s x = debugLog s (goal x)

instance DebugLog Cry.Subst where
  debugLog s x = debugLog s (pp x)

instance DebugLog Prop where
  debugLog s x = debugLog s (ppProp x)



