{-# LANGUAGE Safe, PatternGuards, BangPatterns #-}
-- | Simplification.
-- TODO:
--  - Putting in a normal form to spot "prove by assumption"
--  - Additional simplification rules, namely various cancelation.
--  - Things like:  lg2 e(x) = x, where we know thate is increasing.

module Cryptol.TypeCheck.Solver.Numeric.Simplify
  (
  -- * Simplify a property
  crySimplify, crySimplifyMaybe

  -- * Simplify expressions in a prop
  , crySimpPropExpr, crySimpPropExprMaybe

  -- * Simplify an expression
  , crySimpExpr, crySimpExprMaybe

  , propToProp', ppProp'
  ) where

import           Cryptol.TypeCheck.Solver.Numeric.AST
import qualified Cryptol.TypeCheck.Solver.InfNat as IN
import           Cryptol.Utils.Panic( panic )
import           Cryptol.Utils.Misc ( anyJust )

import           Control.Monad ( mplus, guard, liftM2 )
import           Data.List ( sortBy )
import           Data.Maybe ( fromMaybe, maybeToList )
import qualified Data.Set as Set
import qualified Data.Map as Map
import           Text.PrettyPrint



-- | Simplify a property, if possible.
crySimplify :: Prop -> Prop
crySimplify p = fromMaybe p (crySimplifyMaybe p)

-- | Simplify a property, if possible.
crySimplifyMaybe :: Prop -> Maybe Prop
crySimplifyMaybe p =
  let mbSimpExprs = simpSubs p
      exprsSimped = fromMaybe p mbSimpExprs
      mbRearrange = tryRearrange exprsSimped
      rearranged  = fromMaybe exprsSimped mbRearrange
  in crySimplify `fmap` (crySimpStep rearranged `mplus` mbRearrange
                                                `mplus` mbSimpExprs)

  where
  tryRearrange q = case q of
                    _ :&& _ -> cryRearrangeAnd q
                    _ :|| _ -> cryRearrangeOr  q
                    _       -> Nothing

  simpSubs q = case q of
                Not a     -> Not `fmap` crySimplifyMaybe a
                a :&& b   -> do [a',b'] <- anyJust crySimplifyMaybe [a,b]
                                return (a' :&& b')
                a :|| b   -> do [a',b'] <- anyJust crySimplifyMaybe [a,b]
                                return (a' :|| b')
                _         -> crySimpPropExprMaybe q





-- | A single simplification step.
crySimpStep :: Prop -> Maybe Prop
crySimpStep prop =
  case prop of

    Fin x     -> cryIsFin x   -- Fin only on variables.

    x :== y   -> Just (cryIsEq x y)
    x :>  y   -> Just (cryIsGt x y)

    x :>= y   ->
      case (x,y) of
        (K (Nat 0), _) -> Just (y :== zero)
        (K (Nat a), Width b) -> Just (K (Nat (2 ^ a)) :>= b)

        (_,       K (Nat 0)) -> Just PTrue
        (Width e, K (Nat b)) -> Just (e :>= K (Nat (2^(b-1))))
        (K Inf, _)     -> Just PTrue
        (_, K Inf)     -> Just (x :== inf)
        _              -> Just (x :== inf :|| x :+ one :> y)

    x :==: y ->
      case (x,y) of
        (K a, K b)     -> Just (if a == b then PTrue else PFalse)

        (K (Nat 0), _) -> cryIs0 True y
        (K (Nat 1), _) -> cryIs1 True y
        (_, K (Nat 0)) -> cryIs0 True x
        (_, K (Nat 1)) -> cryIs1 True x

        _ | x == y    -> Just PTrue
          | otherwise -> case (x,y) of
                           (Var _, _) -> Nothing
                           (_, Var _) -> Just (y :==: x)
                           _          -> Nothing

    x :>: y ->
      case (x,y) of
        (K (Nat 0),_)   -> Just PFalse
        (K (Nat 1),_)   -> cryIs0 True y
        (_, K (Nat 0))  -> cryGt0 True x

        _ | x == y      -> Just PFalse
          | otherwise   -> Nothing


    -- For :&& and :|| we assume that the props have been rearrnaged
    p :&& q -> cryAnd p q
    p :|| q -> cryOr p q

    Not p   -> cryNot p
    PFalse  -> Nothing
    PTrue   -> Nothing


-- | Rebalance parens, and arrange conjucts so that we can transfer
-- information left-to-right.
cryRearrangeAnd :: Prop -> Maybe Prop
cryRearrangeAnd prop =
  case rebalance prop of
    Just p  -> Just p
    Nothing -> cryAnds `fmap` cryRearrange cmpAnd (split prop)
  where
  rebalance (a :&& b) =
    case a of
      PFalse    -> Just PFalse
      PTrue     -> Just b
      a1 :&& a2 -> Just (a1 :&& (a2 :&& b))
      _         -> fmap (a :&&) (rebalance b)
  rebalance _ = Nothing

  split (a :&& b) = a : split b
  split a         = [a]


-- | Rebalance parens, and arrange disjuncts so that we can transfer
-- information left-to-right.
cryRearrangeOr :: Prop -> Maybe Prop
cryRearrangeOr prop =
  case rebalance prop of
    Just p  -> Just p
    Nothing -> cryOrs `fmap` cryRearrange cmpOr (split prop)
  where
  rebalance (a :|| b) =
    case a of
      PFalse    -> Just b
      PTrue     -> Just PTrue
      a1 :|| a2 -> Just (a1 :|| (a2 :|| b))
      _         -> fmap (a :||) (rebalance b)
  rebalance _ = Nothing

  split (a :|| b) = a : split b
  split a         = [a]




-- | Identify propositions that are suiatable for inlining.
cryIsDefn :: Prop -> Maybe (Name, Expr)
cryIsDefn (Var x :==: e) = if (x `Set.member` cryExprFVS e)
                              then Nothing
                              else Just (x,e)
cryIsDefn _              = Nothing





type PropOrdering = (Int,Prop) -> (Int,Prop) -> Ordering

{- | Rearrange proposition for conjuctions and disjunctions.

information left-to-right, so we put proposition with information content
on the left.
-}
cryRearrange :: PropOrdering -> [Prop] -> Maybe [Prop]
cryRearrange cmp ps = if ascending keys then Nothing else Just sortedProps
  where
  -- We tag each proposition with a number, so that later we can tell easily
  -- if the propositions got rearranged.
  (keys, sortedProps) = unzip (sortBy cmp (zip [ 0 :: Int .. ] ps))

  ascending (x : y : zs) = x < y && ascending (y : zs)
  ascending _            = True


cmpAnd :: PropOrdering
cmpAnd (k1,prop1) (k2,prop2) =
  case (prop1, prop2) of

    -- First comes PFalse, maybe we don't need to do anything
    (PFalse, PFalse) -> compare k1 k2
    (PFalse, _)      -> LT
    (_,PFalse)       -> GT

    -- Next comes PTrue
    (PTrue, PTrue)   -> compare k1 k2
    (PTrue, _)       -> LT
    (_,PTrue)        -> GT

    -- Next come `not (fin a)`  (i.e, a = inf)
    (Not (Fin (Var x)), Not (Fin (Var y))) -> cmpVars x y
    (Not (Fin (Var _)), _)                 -> LT
    (_, Not (Fin (Var _)))                 -> GT

    -- Next come defintions: `x = e` (with `x` not in `fvs e`)
    -- XXX: Inefficient, because we keep recomputing free variables
    -- (here, and then when actually applying the substitution)
    _ | Just (x,_) <- mbL
      , Just (y,_) <- mbR  -> cmpVars x y
      | Just _     <- mbL  -> LT
      | Just _     <- mbR  -> GT
      where
      mbL = cryIsDefn prop1
      mbR = cryIsDefn prop2

    -- Next come `fin a`
    (Fin (Var x), Fin (Var y)) -> cmpVars x y
    (Fin (Var _), _)           -> LT
    (_, Fin (Var _))           -> GT

    -- Everything else stays as is
    _ -> compare k1 k2

  where
  cmpVars x y
    | x < y     = LT
    | x > y     = GT
    | otherwise = compare k1 k2


cmpOr :: PropOrdering
cmpOr (k1,prop1) (k2,prop2) =
  case (prop1, prop2) of

    -- First comes PTrue, maybe we don't need to do anything
    (PTrue, PTrue)   -> compare k1 k2
    (PTrue, _)       -> LT
    (_,PTrue)        -> GT

    -- Next comes PFalse
    (PFalse, PFalse) -> compare k1 k2
    (PFalse, _)      -> LT
    (_,PFalse)       -> GT

    -- Next comes `fin a` (because we propagete `a = inf`)
    (Fin (Var x), Fin (Var y)) -> cmpVars x y
    (Fin (Var _), _)           -> LT
    (_, Fin (Var _))           -> GT

    -- Next come `not (fin a)`  (i.e, propagete (fin a))
    (Not (Fin (Var x)), Not (Fin (Var y))) -> cmpVars x y
    (Not (Fin (Var _)), _)                 -> LT
    (_, Not (Fin (Var _)))                 -> GT

    -- we don't propagete (x /= e) for now.

    -- Everything else stays as is
    _ -> compare k1 k2

  where
  cmpVars x y
    | x < y     = LT
    | x > y     = GT
    | otherwise = compare k1 k2





-- | Simplification of ':&&'.
-- Assumes arranged conjucntions.
-- See 'cryRearrangeAnd'.
cryAnd :: Prop -> Prop -> Maybe Prop
cryAnd p q =
  case p of
    PTrue       -> Just q

    PFalse      -> Just PFalse

    Not (Fin (Var x))
      | Just q' <- cryKnownFin x False q -> Just (p :&& q')

    Fin (Var x)
      | Just q' <- cryKnownFin x True q -> Just (p :&& q')

    _ | Just (x,e) <- cryIsDefn p
      , Just q'    <- cryLet x e q
      -> Just (p :&& q')

    _ -> Nothing


-- | Simplification of ':||'.
-- Assumes arranged disjunctions.
-- See 'cryRearrangeOr'
cryOr :: Prop -> Prop -> Maybe Prop
cryOr p q =
  case p of
    PTrue     -> Just PTrue

    PFalse    -> Just q

    Fin (Var x)
      | Just q' <- cryKnownFin x False q -> Just (p :|| q')

    Not (Fin (Var x))
      | Just q' <- cryKnownFin x True q -> Just (p :|| q')

    _ -> Nothing



-- | Propagate the fact that the variable is known to be finite ('True')
-- or not-finite ('False').
-- Note that this may introduce new expression redexes.
cryKnownFin :: Name -> Bool -> Prop -> Maybe Prop
cryKnownFin a isFin prop =
  case prop of
    Fin (Var a') | a == a' -> Just (if isFin then PTrue else PFalse)

    p :&& q -> do [p',q'] <- anyJust (cryKnownFin a isFin) [p,q]
                  return (p' :&& q')

    p :|| q -> do [p',q'] <- anyJust (cryKnownFin a isFin) [p,q]
                  return (p' :|| q')

    Not p   -> Not `fmap` cryKnownFin a isFin p

    x :==: y
      | not isFin, Just [x',y'] <- anyJust (cryLet a inf) [x,y]
      -> Just (cryNatOp (:==:) x' y')

    x :>: y
      | not isFin, Just [x',y'] <- anyJust (cryLet a inf) [x,y]
      -> Just (cryNatOp (:>:) x' y')

    -- All the other cases should be simplified, eventually.
    _       -> Nothing




-- | Negation.
cryNot :: Prop -> Maybe Prop
cryNot prop =
  case prop of
    Fin _           -> Nothing

    x :== y         -> Just (x :> y :|| y :> x)
    x :>= y         -> Just (y :>  x)
    x :>  y         -> Just (y :>= x)

    x :==: y        -> Just (x :>: y :|| y :>: x)

    _ :>: _         -> Nothing

    p :&& q         -> Just (Not p :|| Not q)
    p :|| q         -> Just (Not p :&& Not q)
    Not p           -> Just p
    PFalse          -> Just PTrue
    PTrue           -> Just PFalse



-- | Simplificaiton for @:==@
cryIsEq :: Expr -> Expr -> Prop
cryIsEq x y =
  case (x,y) of
    (K m, K n)      -> if m == n then PTrue else PFalse

    (K (Nat 0),_)   -> cryIs0' y
    (K (Nat 1),_)   -> cryIs1' y
    (_, K (Nat 0))  -> cryIs0' x
    (_, K (Nat 1))  -> cryIs1' x

    (K Inf, _)      -> Not (Fin y)
    (_, K Inf)      -> Not (Fin x)

    _               -> Not (Fin x) :&& Not (Fin y)
                   :|| Fin x :&& Fin y :&& cryNatOp (:==:) x y
  where
  cryIs0' e = case cryIs0 False e of
                Just e' -> e'
                Nothing -> panic "cryIsEq"
                                 ["`cryIs0 False` returned `Nothing`."]

  cryIs1' e = case cryIs1 False e of
                Just e' -> e'
                Nothing -> panic "cryIsEq"
                                 ["`cryIs0 False` returned `Nothing`."]




-- | Simplificatoin for @:>@
cryIsGt :: Expr -> Expr -> Prop
cryIsGt (K m) (K n)   = if m > n then PTrue else PFalse
cryIsGt (K (Nat 0)) _ = PFalse
cryIsGt (K (Nat 1)) e = case cryIs0 False e of
                          Just e' -> e'
                          Nothing -> panic "cryIsGt (1)"
                                           ["`cryGt0 False` return `Nothing`"]
cryIsGt e (K (Nat 0)) = case cryGt0 False e of
                          Just e' -> e'
                          Nothing -> panic "cryIsGt (2)"
                                           ["`cryGt0 False` return `Nothing`"]
cryIsGt x y           = Fin y :&& (x :== inf :||
                                   Fin x :&& cryNatOp (:>:) x y)



-- | Attempt to simplify a @fin@ constraint.
-- Assumes a defined input.
cryIsFin :: Expr -> Maybe Prop
cryIsFin expr =
  case expr of
    K Inf                -> Just PFalse
    K (Nat _)            -> Just PTrue
    Var _                -> Nothing
    t1 :+ t2             -> Just (Fin t1 :&& Fin t2)
    t1 :- _              -> Just (Fin t1)

    t1 :* t2             -> Just ( Fin t1 :&& Fin t2
                               :|| t1 :== zero :&& t2 :== inf
                               :|| t2 :== zero :&& t1 :== inf
                                 )

    Div t1 _             -> Just (Fin t1)
    Mod _ _              -> Just PTrue

    t1 :^^ t2            ->
      Just ( Fin t1 :&& Fin t2
         :|| t1 :== inf :&& t2 :== zero   -- inf ^^ 0
         :|| t2 :== inf :&& (t1 :== zero :|| t1 :== one)
                             -- 0 ^^ inf,    1 ^^ inf
           )

    Min t1 t2            -> Just (Fin t1 :|| Fin t2)
    Max t1 t2            -> Just (Fin t1 :&& Fin t2)
    Lg2 t1               -> Just (Fin t1)
    Width t1             -> Just (Fin t1)
    LenFromThen  _ _ _   -> Just PTrue
    LenFromThenTo  _ _ _ -> Just PTrue



--------------------------------------------------------------------------------
-- An alternative representation

data Atom = AFin Name | AGt Expr Expr | AEq Expr Expr
            deriving Eq

type Prop' = IfExpr' Atom Bool

-- tmp
propToProp' :: Prop -> Prop'
propToProp' prop =
  case prop of
    Fin e     -> pFin e
    x :== y   -> pEq x y
    x :>= y   -> pGeq x y
    x :>  y   -> pGt  x y
    x :>: y   -> pAnd (pFin x) (pAnd (pFin y) (pGt x y))
    x :==: y  -> pAnd (pFin x) (pAnd (pFin y) (pEq x y))
    p :&& q   -> pAnd (propToProp' p) (propToProp' q)
    p :|| q   -> pOr  (propToProp' p) (propToProp' q)
    Not p     -> pNot (propToProp' p)
    PFalse    -> pFalse
    PTrue     -> pTrue



ppAtom :: Atom -> Doc
ppAtom atom =
  case atom of
    AFin x  -> text "fin" <+> ppName x
    AGt x y -> ppExpr x <+> text ">" <+> ppExpr y
    AEq x y -> ppExpr x <+> text "=" <+> ppExpr y

ppProp' :: Prop' -> Doc
ppProp' = ppIf ppAtom (text . show)

pEq :: Expr -> Expr -> Prop'
pEq x (K (Nat 0)) = pEq0 x
pEq x (K (Nat 1)) = pEq1 x
pEq (K (Nat 0)) y = pEq0 y
pEq (K (Nat 1)) y = pEq1 y
pEq x y = pIf (pInf x) (pInf y)
        $ pAnd (pFin y) (pAtom (AEq x y))

pGeq :: Expr -> Expr -> Prop'
pGeq x y = pIf (pInf x) pTrue
         $ pIf (pFin y) (pAtom (AGt (x :+ one) y))
           pFalse

pFin :: Expr -> Prop'
pFin expr =
  case expr of
    K Inf                -> pFalse
    K (Nat _)            -> pTrue
    Var x                -> pAtom (AFin x)
    t1 :+ t2             -> pAnd (pFin t1) (pFin t2)
    t1 :- _              -> pFin t1
    t1 :* t2             -> pIf (pInf t1) (pEq t2 zero)
                          $ pIf (pInf t2) (pEq t1 zero)
                          $ pTrue

    Div t1 _             -> pFin t1
    Mod _ _              -> pTrue

    t1 :^^ t2            -> pIf (pInf t1) (pEq t2 zero)
                          $ pIf (pInf t2) (pOr (pEq t1 zero) (pEq t1 one))
                          $ pTrue


    Min t1 t2            -> pOr (pFin t1) (pFin t2)
    Max t1 t2            -> pAnd (pFin t1) (pFin t2)
    Lg2 t1               -> pFin t1
    Width t1             -> pFin t1
    LenFromThen  _ _ _   -> pTrue
    LenFromThenTo  _ _ _ -> pTrue



pFalse :: Prop'
pFalse = Return False

pTrue :: Prop'
pTrue = Return True

pNot :: Prop' -> Prop'
pNot p =
  case p of
    Impossible -> Impossible
    Return a   -> Return (not a)
    If c t e   -> If c (pNot t) (pNot e)

pAnd :: Prop' -> Prop' -> Prop'
pAnd p q = pIf p q pFalse

pOr :: Prop' -> Prop' -> Prop'
pOr p q = pIf p pTrue q

pIf :: (Eq a, Eq p) =>
        IfExpr' p Bool -> IfExpr' p a -> IfExpr' p a -> IfExpr' p a
pIf c t e =
  case c of
    Impossible    -> Impossible
    Return True   -> t
    Return False  -> e
    _ | t == e    -> t
    If p t1 e1    -> If p (pIf t1 t e) (pIf e1 t e) -- duplicates

pAtom :: Atom -> Prop'
pAtom p = do a <- case p of
                    AFin _  -> return p
                    AEq x y -> liftM2 AEq (eNoInf x) (eNoInf y)
                    AGt x y -> liftM2 AGt (eNoInf x) (eNoInf y)
             If a pTrue pFalse

pGt :: Expr -> Expr -> Prop'
pGt x y = pIf (pFin y) (pIf (pFin x) (pAtom (AGt x y)) pTrue) pFalse

pEq0 :: Expr -> Prop'
pEq0 expr =
  case expr of
    K Inf               -> pFalse
    K (Nat n)           -> if n == 0 then pTrue else pFalse
    Var _               -> pAnd (pFin expr) (pAtom (AEq expr zero))
    t1 :+ t2            -> pAnd (pEq t1 zero) (pEq t2 zero)
    t1 :- t2            -> pEq t1 t2
    t1 :* t2            -> pOr (pEq t1 zero) (pEq t2 zero)
    Div t1 t2           -> pGt t2 t1
    Mod _ _             -> pAtom (AEq expr zero)  -- or divides
    t1 :^^ t2           -> pIf (pEq t2 zero) pFalse (pEq t1 zero)
    Min t1 t2           -> pOr  (pEq t1 zero) (pEq t2 zero)
    Max t1 t2           -> pAnd (pEq t1 zero) (pEq t2 zero)
    Lg2 t1              -> pOr  (pEq t1 zero) (pEq t1 one)
    Width t1            -> pEq t1 zero
    LenFromThen _ _ _   -> pFalse
    LenFromThenTo x y z -> pIf (pGt x y) (pGt z x) (pGt x z)

pEq1 :: Expr -> Prop'
pEq1 expr =
  case expr of
    K Inf               -> pFalse
    K (Nat n)           -> if n == 1 then pTrue else pFalse
    Var _               -> pAnd (pFin expr) (pAtom (AEq expr one))
    t1 :+ t2            -> pIf (pEq t1 zero) (pEq t2 one)
                         $ pIf (pEq t2 zero) (pEq t1 one) pFalse
    t1 :- t2            -> pEq t1 (t2 :+ one)
    t1 :* t2            -> pAnd (pEq t1 one) (pEq t2 one)
    Div t1 t2           -> pAnd (pGt (two :* t2) t1) (pGeq t1 t2)
    Mod _ _             -> pAtom (AEq expr one)
    t1 :^^ t2           -> pOr (pEq t1 one) (pEq t2 zero)

    Min t1 t2           -> pIf (pEq t1 one) (pGt t2 zero)
                         $ pIf (pEq t2 one) (pGt t1 zero)
                           pFalse
    Max t1 t2           -> pIf (pEq t1 one) (pGt two t2)
                         $ pIf (pEq t2 one) (pGt two t1)
                           pFalse

    Lg2 t1              -> pEq t1 two
    Width t1            -> pEq t1 one

    -- See Note [Sequences of Length 1] in 'Cryptol.TypeCheck.Solver.InfNat'
    LenFromThen x y w   -> pAnd (pGt y x) (pGeq y (two :^^ w))
    LenFromThenTo x y z -> pIf (pGt z y) (pGeq x z) (pGeq z x)


pInf :: Expr -> Prop'
pInf = pNot . pFin



type IExpr = IfExpr' Atom Expr

-- | Our goal is to bubble @inf@ terms to the top of @Return@.
eNoInf :: Expr -> IExpr
eNoInf expr =
  case expr of

    -- These are the interesting cases where we have to branch

    x :* y ->
      do x' <- eNoInf x
         y' <- eNoInf y
         case (x', y') of
           (K Inf, K Inf) -> return inf
           (K Inf, _)     -> pIf (pEq y' zero) (return zero) (return inf)
           (_, K Inf)     -> pIf (pEq x' zero) (return zero) (return inf)
           _              -> return (x' :* y')

    x :^^ y ->
      do x' <- eNoInf x
         y' <- eNoInf y
         case (x', y') of
           (K Inf, K Inf) -> return inf
           (K Inf, _)     -> pIf (pEq y' zero) (return one) (return inf)
           (_, K Inf)     -> pIf (pEq x' zero) (return zero)
                           $ pIf (pEq x' one)  (return one)
                           $ return inf
           _              -> return (x' :^^ y')


    -- The rest just propagates

    K _     -> return expr
    Var _   -> return expr

    x :+ y  ->
      do x' <- eNoInf x
         y' <- eNoInf y
         case (x', y') of
           (K Inf, _)  -> return inf
           (_, K Inf)  -> return inf
           _           -> return (x' :+ y')

    x :- y  ->
      do x' <- eNoInf x
         y' <- eNoInf y
         case (x', y') of
           (_, K Inf)  -> Impossible
           (K Inf, _)  -> return inf
           _           -> return (x' :- y')

    Div x y ->
      do x' <- eNoInf x
         y' <- eNoInf y
         case (x', y') of
           (K Inf, _) -> Impossible
           (_, K Inf) -> return zero
           _          -> return (Div x' y')

    Mod x y ->
      do x' <- eNoInf x
         -- `Mod x y` is finite, even if `y` is `inf`, so first check
         -- for finiteness.
         pIf (pFin y)
              (do y' <- eNoInf y
                  case (x',y') of
                    (K Inf, _) -> Impossible
                    (_, K Inf) -> Impossible
                    _          -> return (Mod x' y')
              )
              (return x')

    Min x y ->
      do x' <- eNoInf x
         y' <- eNoInf y
         case (x',y') of
           (K Inf, _) -> return y'
           (_, K Inf) -> return x'
           _          -> return (Min x' y')

    Max x y ->
      do x' <- eNoInf x
         y' <- eNoInf y
         case (x', y') of
           (K Inf, _) -> return inf
           (_, K Inf) -> return inf
           _          -> return (Max x' y')

    Lg2 x ->
      do x' <- eNoInf x
         case x' of
           K Inf     -> return inf
           _         -> return (Lg2 x')

    Width x ->
      do x' <- eNoInf x
         case x' of
           K Inf      -> return inf
           _          -> return (Width x')

    LenFromThen x y w   -> fun3 LenFromThen x y w
    LenFromThenTo x y z -> fun3 LenFromThenTo x y z


  where
  fun3 f x y z =
    do x' <- eNoInf x
       y' <- eNoInf y
       z' <- eNoInf z
       case (x',y',z') of
         (K Inf, _, _) -> Impossible
         (_, K Inf, _) -> Impossible
         (_, _, K Inf) -> Impossible
         _             -> return (f x' y' z')


--------------------------------------------------------------------------------




-- | Simplify @t :== 0@ or @t :==: 0@.
-- Assumes defined input.
cryIs0 :: Bool -> Expr -> Maybe Prop
cryIs0 useFinite expr =
  case expr of
    K Inf               -> Just PFalse
    K (Nat n)           -> Just (if n == 0 then PTrue else PFalse)
    Var _ | useFinite   -> Nothing
          | otherwise   -> Just (Fin expr :&& expr :==: zero)
    t1 :+ t2            -> Just (eq t1 zero :&& eq t2 zero)
    t1 :- t2            -> Just (eq t1 t2)
    t1 :* t2            -> Just (eq t1 zero :|| eq t2 zero)
    Div t1 t2           -> Just (gt t2 t1)
    Mod _ _ | useFinite -> Nothing
            | otherwise -> Just (cryNatOp (:==:) expr zero)
            -- or: Just (t2 `Divides` t1)
    t1 :^^ t2           -> Just (eq t1 zero :&& gt t2 zero)
    Min t1 t2           -> Just (eq t1 zero :|| eq t2 zero)
    Max t1 t2           -> Just (eq t1 zero :&& eq t2 zero)
    Lg2 t1              -> Just (eq t1 zero :|| eq t1 one)
    Width t1            -> Just (eq t1 zero)
    LenFromThen _ _ _   -> Just PFalse

    -- See `nLenFromThenTo` in 'Cryptol.TypeCheck.Solver.InfNat'
    LenFromThenTo x y z -> Just ( gt x y :&& gt z x
                              :|| gt y x :&& gt x z
                                )

  where
  eq x y = if useFinite then x :==: y else x :== y
  gt x y = if useFinite then x :>: y  else x :>  y


cryIs1 :: Bool -> Expr -> Maybe Prop
cryIs1 useFinite expr =
  case expr of
    K Inf               -> Just PFalse
    K (Nat n)           -> Just (if n == 1 then PTrue else PFalse)
    Var _ | useFinite   -> Nothing
          | otherwise   -> Just (Fin expr :&& expr :==: one)
    t1 :+ t2            -> Just (eq t1 zero :&& eq t2 one :||
                                 eq t1 one  :&& eq t1 zero)
    t1 :- t2            -> Just (eq t1 (t2 :+ one))
    t1 :* t2            -> Just (eq t1 one :&& eq t2 one)

    Div t1 t2           -> Just (gt (two :* t2) t1 :&& gt (t1 :+ one) t2)

    Mod _ _ | useFinite -> Nothing
            | otherwise -> Just (cryNatOp (:==:) expr one)


    t1 :^^ t2           -> Just (eq t1 one :|| eq t2 zero)

    Min t1 t2           -> Just (eq t1 one :&& gt t2 zero :||
                                 eq t2 one :&& gt t1 zero)

    Max t1 t2           -> Just (eq t1 one :&& gt two t2 :||
                                 eq t2 one :&& gt two t1)

    Lg2 t1              -> Just (eq t1 two)
    Width t1            -> Just (eq t1 one)

    -- See Note [Sequences of Length 1] in 'Cryptol.TypeCheck.Solver.InfNat'
    LenFromThen x y w   -> Just (gt y x :&& gt (y :+ one) (two :^^ w))

    -- See Note [Sequences of Length 1] in 'Cryptol.TypeCheck.Solver.InfNat'
    LenFromThenTo x y z -> Just (gt z y :&& gt (x :+ one) z     :||
                                 gt y z :&& gt (z :+ one) x)
  where
  eq x y = if useFinite then x :==: y else x :== y
  gt x y = if useFinite then x :>: y  else x :>  y










-- | Simplify @t :> 0@ or @t :>: 0@.
cryGt0 :: Bool -> Expr -> Maybe Prop
cryGt0 useFinite expr =
  case expr of
    K x                 -> Just (if x > Nat 0 then PTrue else PFalse)
    Var _ | useFinite   -> Nothing
          | otherwise   -> Just (Not (Fin expr) :||
                                 Fin expr :&& cryNatOp (:>:) expr zero)
    x :+ y              -> Just (gt x zero :|| gt y zero)
    x :- y              -> Just (gt x y)
    x :* y              -> Just (gt x zero :&& gt y zero)
    Div x y             -> Just (gt x y)
    Mod _ _ | useFinite -> Nothing
            | otherwise -> Just (cryNatOp (:>:) expr zero)
            -- or: Just (Not (y `Divides` x))
    x :^^ y             -> Just (eq x zero :&& gt y zero)
    Min x y             -> Just (gt x zero :&& gt y zero)
    Max x y             -> Just (gt x zero :|| gt y zero)
    Lg2 x               -> Just (gt x one)
    Width x             -> Just (gt x zero)
    LenFromThen _ _ _   -> Just PTrue
    LenFromThenTo x y z -> Just (gt x y :&& gt z x :|| gt y x :&& gt x z)

  where
  eq x y = if useFinite then x :==: y else x :== y
  gt x y = if useFinite then x :>: y  else x :>  y


-- | Simplify only the Expr parts of a Prop.
crySimpPropExpr :: Prop -> Prop
crySimpPropExpr p = fromMaybe p (crySimpPropExprMaybe p)

-- | Simplify only the Expr parts of a Prop.
-- Returns `Nothing` if there were no changes.
crySimpPropExprMaybe  :: Prop -> Maybe Prop
crySimpPropExprMaybe prop =
  case prop of

    Fin e                 -> Fin `fmap` crySimpExprMaybe e

    a :==  b              -> binop crySimpExprMaybe (:== ) a b
    a :>=  b              -> binop crySimpExprMaybe (:>= ) a b
    a :>   b              -> binop crySimpExprMaybe (:>  ) a b
    a :==: b              -> binop crySimpExprMaybe (:==:) a b
    a :>:  b              -> binop crySimpExprMaybe (:>: ) a b

    a :&& b               -> binop crySimpPropExprMaybe (:&&) a b
    a :|| b               -> binop crySimpPropExprMaybe (:||) a b

    Not p                 -> Not `fmap` crySimpPropExprMaybe p

    PFalse                -> Nothing
    PTrue                 -> Nothing

  where

  binop simp f l r =
    case (simp l, simp r) of
      (Nothing,Nothing) -> Nothing
      (l',r')           -> Just (f (fromMaybe l l') (fromMaybe r r'))



-- | Simplify an expression, if possible.
crySimpExpr :: Expr -> Expr
crySimpExpr expr = fromMaybe expr (crySimpExprMaybe expr)

-- | Perform simplification from the leaves up.
-- Returns `Nothing` if there were no changes.
crySimpExprMaybe :: Expr -> Maybe Expr
crySimpExprMaybe expr =
  case crySimpExprStep (fromMaybe expr mbE1) of
    Nothing -> mbE1
    Just e2 -> Just (fromMaybe e2 (crySimpExprMaybe e2))
  where
  mbE1 = cryRebuildExpr expr `fmap` anyJust crySimpExprMaybe (cryExprExprs expr)



-- XXX: Add rules to group together occurances of variables


data Sign = Pos | Neg deriving Show

otherSign :: Sign -> Sign
otherSign s = case s of
                Pos -> Neg
                Neg -> Pos

signed :: Sign -> Integer -> Integer
signed s = case s of
             Pos -> id
             Neg -> negate


splitSum :: Expr -> [(Sign,Expr)]
splitSum e0 = go Pos e0 []
  where go s (e1 :+ e2) es = go s e1 (go s e2 es)
        go s (e1 :- e2) es = go s e1 (go (otherSign s) e2 es)
        go s e es          = (s,e) : es

normSum :: Expr -> Expr
normSum = posTerm . go 0 Map.empty Nothing . splitSum
  where

  -- constants, variables, other terms
  go !_ !_  !_ ((Pos,K Inf) : _) = (Pos, K Inf)

  go k xs t ((s, K (Nat n)) : es) = go (k + signed s n) xs t es

  go k xs t ((s, Var x) : es) = go k (Map.insertWith (+) x (signed s 1) xs) t es

  go k xs t ((s, K (Nat n) :* Var x) : es)
    | n == 0     = go k xs t es
    | otherwise  = go k (Map.insertWith (+) x (signed s n) xs) t es

  go k xs Nothing (e : es) = go k xs (Just e) es

  go k xs (Just e1) (e2 : es) = go k xs (Just (add e1 e2)) es

  go k xs t [] =
    let terms     = constTerm k
                 ++ concatMap varTerm (Map.toList xs)
                 ++ maybeToList t

    in case terms of
         [] -> (Pos, K (Nat 0))
         ts -> foldr1 add ts

  constTerm k
    | k == 0    = []
    | k >  0    = [ (Pos, K (Nat k)) ]
    | otherwise = [ (Neg, K (Nat (negate k))) ]

  varTerm (x,k)
    | k == 0    = []
    | k == 1    = [ (Pos, Var x) ]
    | k > 0     = [ (Pos, K (Nat k) :* Var x) ]
    | k == (-1) = [ (Neg, Var x) ]
    | otherwise = [ (Neg, K (Nat (negate k)) :* Var x) ]

  add (s1,t1) (s2,t2) =
    case (s1,s2) of
      (Pos,Pos) -> (Pos, t1 :+ t2)
      (Pos,Neg) -> (Pos, t1 :- t2)
      (Neg,Pos) -> (Pos, t2 :- t1)
      (Neg,Neg) -> (Neg, t1 :+ t2)

  posTerm (Pos,x) = x
  posTerm (Neg,x) = K (Nat 0) :- x


crySimpExprStep :: Expr -> Maybe Expr
crySimpExprStep e =
  case crySimpExprStep1 e of
    Just e1 -> Just e1
    Nothing -> do let e1 = normSum e
                  guard (e /= e1)
                  return e1

-- | Make a simplification step, assuming the expression is well-formed.
crySimpExprStep1 :: Expr -> Maybe Expr
crySimpExprStep1 expr =
  case expr of
    K _                   -> Nothing
    Var _                 -> Nothing

    _ :+ _                -> Nothing
    _ :- _                -> Nothing

    x :* y ->
      case (x,y) of
        (K (Nat 0), _)    -> Just zero
        (K (Nat 1), _)    -> Just y
        (K a, K b)        -> Just (K (IN.nMul a b))
        (_,   K _)        -> Just (y :* x)

        (K a, K b :* z)   -> Just (K (IN.nMul a b) :* z)

        -- Normalize, somewhat
        (a :* b, _)       -> Just (a :* (b :* y))
        (Var a, Var b)
          | b > a         -> Just (y :* x)

        _                 -> Nothing

    Div x y ->
      case (x,y) of
        (K (Nat 0), _)    -> Just zero
        (_, K (Nat 1))    -> Just x
        (_, K Inf)        -> Just zero
        (K a, K b)        -> K `fmap` IN.nDiv a b
        _ | x == y        -> Just one
        _                 -> Nothing

    Mod x y ->
      case (x,y) of
        (K (Nat 0), _)    -> Just zero
        (_, K Inf)        -> Just x
        (_, K (Nat 1))    -> Just zero
        (K a, K b)        -> K `fmap` IN.nMod a b
        _                 -> Nothing

    x :^^ y ->
      case (x,y) of
        (_, K (Nat 0))    -> Just one
        (_, K (Nat 1))    -> Just x
        (K (Nat 1), _)    -> Just one
        (K a, K b)        -> Just (K (IN.nExp a b))
        _                 -> Nothing

    Min x y ->
      case (x,y) of
        (K (Nat 0), _)    -> Just zero
        (K Inf, _)        -> Just y
        (_, K (Nat 0))    -> Just zero
        (_, K Inf)        -> Just x
        (K a, K b)        -> Just (K (IN.nMin a b))
        _ | x == y        -> Just x
        _                 -> Nothing

    Max x y ->
      case (x,y) of
        (K (Nat 0), _)    -> Just y
        (K Inf, _)        -> Just inf
        (_, K (Nat 0))    -> Just x
        (_, K Inf)        -> Just inf
        _ | x == y        -> Just x
        _                 -> Nothing

    Lg2 x ->
      case x of
        K a               -> Just (K (IN.nLg2 a))
        K (Nat 2) :^^ e   -> Just e
        _                 -> Nothing

    -- Width x               -> Just (Lg2 (x :+ one))
    Width x ->
      case x of
        K a              -> Just (K (IN.nWidth a))
        K (Nat 2) :^^ e  -> Just (one :+ e)
        _                -> Nothing

    LenFromThen x y w ->
      case (x,y,w) of
        (K a, K b, K c)   -> K `fmap` IN.nLenFromThen a b c
        _                 -> Nothing

    LenFromThenTo x y z ->
      case (x,y,z) of
        (K a, K b, K c)   -> K `fmap` IN.nLenFromThenTo a b c
        _                 -> Nothing




-- | Our goal is to bubble @inf@ terms to the top of @Return@.
cryNoInf :: Expr -> IfExpr Expr
cryNoInf expr =
  case expr of

    -- These are the interesting cases where we have to branch

    x :* y ->
      do x' <- cryNoInf x
         y' <- cryNoInf y
         case (x', y') of
           (K Inf, K Inf) -> return inf
           (K Inf, _)     -> mkIf (y' :==: zero) (return zero) (return inf)
           (_, K Inf)     -> mkIf (x' :==: zero) (return zero) (return inf)
           _              -> return (x' :* y')

    x :^^ y ->
      do x' <- cryNoInf x
         y' <- cryNoInf y
         case (x', y') of
           (K Inf, K Inf) -> return inf
           (K Inf, _)     -> mkIf (y' :==: zero) (return one) (return inf)
           (_, K Inf)     -> mkIf (x' :==: zero) (return zero)
                           $ mkIf (x' :==: one)  (return one)
                           $ return inf
           _              -> return (x' :^^ y')



    -- The rest just propagates

    K _     -> return expr
    Var _   -> return expr

    x :+ y  ->
      do x' <- cryNoInf x
         y' <- cryNoInf y
         case (x', y') of
           (K Inf, _)  -> return inf
           (_, K Inf)  -> return inf
           _           -> return (x' :+ y')

    x :- y  ->
      do x' <- cryNoInf x
         y' <- cryNoInf y
         case (x', y') of
           (_, K Inf)  -> Impossible
           (K Inf, _)  -> return inf
           _           -> mkIf (x' :==: y)
                               (return zero)
                               (mkIf (x' :>: y) (return (x' :- y'))
                                                Impossible)

    Div x y ->
      do x' <- cryNoInf x
         y' <- cryNoInf y
         case (x', y') of
           (K Inf, _) -> Impossible
           (_, K Inf) -> return zero
           _          -> mkIf (y' :>: zero) (return (Div x' y')) Impossible

    Mod x y ->
      do x' <- cryNoInf x
         -- `Mod x y` is finite, even if `y` is `inf`, so first check
         -- for finiteness.
         mkIf (Fin y)
              (do y' <- cryNoInf y
                  case (x',y') of
                    (K Inf, _) -> Impossible
                    (_, K Inf) -> Impossible
                    _ -> mkIf (y' :>: zero) (return (Mod x' y')) Impossible
              )
              (return x')

    Min x y ->
      do x' <- cryNoInf x
         y' <- cryNoInf y
         case (x',y') of
           (K Inf, _) -> return y'
           (_, K Inf) -> return x'
           _          -> return (Min x' y')

    Max x y ->
      do x' <- cryNoInf x
         y' <- cryNoInf y
         case (x', y') of
           (K Inf, _) -> return inf
           (_, K Inf) -> return inf
           _          -> return (Max x' y')

    Lg2 x ->
      do x' <- cryNoInf x
         case x' of
           K Inf     -> return inf
           _         -> return (Lg2 x')

    Width x ->
      do x' <- cryNoInf x
         case x' of
           K Inf      -> return inf
           _          -> return (Width x')

    LenFromThen x y w   -> fun3 LenFromThen x y w
    LenFromThenTo x y z -> fun3 LenFromThenTo x y z


  where
  fun3 f x y z =
    do x' <- cryNoInf x
       y' <- cryNoInf y
       z' <- cryNoInf z
       case (x',y',z') of
         (K Inf, _, _) -> Impossible
         (_, K Inf, _) -> Impossible
         (_, _, K Inf) -> Impossible
         _             -> mkIf (x' :==: y') Impossible
                                            (return (f x' y' z'))

  mkIf p t e = case crySimplify p of
                 PTrue  -> t
                 PFalse -> e
                 p'     -> If p' t e




-- | Make an expression that should work ONLY on natural nubers.
-- Eliminates occurances of @inf@.
-- Assumes that the two input expressions are well-formed and finite.
-- The expression is constructed by the given function.
cryNatOp :: (Expr -> Expr -> Prop) -> Expr -> Expr -> Prop
cryNatOp op x y =
  toProp $
  do x' <- noInf x
     y' <- noInf y
     return (op x' y')
  where
  noInf a = do a' <- cryNoInf a
               case a' of
                 K Inf -> Impossible
                 _     -> return a'

  toProp ite =
    case ite of
      Impossible -> PFalse -- It doesn't matter, but @false@ might anihilate.
      Return p   -> p
      If p t e   -> p :&& toProp t :|| Not p :&& toProp e



