{-# LANGUAGE Safe #-}
module Cryptol.TypeCheck.Solver.CrySAT1 where

import Cryptol.TypeCheck.Solver.InfNat(Nat'(..))
import qualified Cryptol.TypeCheck.Solver.InfNat as IN
import Text.PrettyPrint
import Data.Maybe(fromMaybe)
import Data.List(unfoldr)
import Control.Monad(liftM, ap)
import qualified Control.Applicative as A


test =
  do print (ppExpr expr)
     mapM_ (print . ppProp)
       $ crySimpSteps
       $ cryDefined expr
  where
  a : b : c : d : _ = map (Var . Name) [ 0 .. ]

  expr = Div a b
  rest = Min (a :* b) (inf :* (inf :* (c :+ d)))


--------------------------------------------------------------------------------
newtype Name = Name Int
              deriving (Eq,Show)

infixr 2 :||
infixr 3 :&&
infix  4 :==, :>, :>=, :==:, :>:
infixl 6 :+, :-
infixl 7 :*
infixr 8 :^^



-- | Propopsitions, representing Cryptol's numeric constraints (and a bit more).

data Prop = -- Preidcates on natural numbers with infinity.
            Fin Expr
          | Expr :== Expr
          | Expr :>= Expr | Expr :> Expr

          -- Predicate on strict natural numbers (i.e., no infinities)
          | Expr :==: Expr | Expr :>: Expr

          -- Standard logical strucutre
          | Prop :&& Prop | Prop :|| Prop
          | Not Prop
          | PFalse | PTrue
            deriving Show

-- | Expressions, representing Cryptol's numeric types.
data Expr = K Nat'
          | Var Name
          | Expr :+ Expr
          | Expr :- Expr
          | Expr :* Expr
          | Div Expr Expr
          | Mod Expr Expr
          | Expr :^^ Expr
          | Min Expr Expr
          | Max Expr Expr
          | Lg2 Expr
          | Width Expr
          | LenFromThen   Expr Expr Expr
          | LenFromThenTo Expr Expr Expr
            deriving (Eq,Show)

zero :: Expr
zero = K (Nat 0)

one :: Expr
one = K (Nat 1)

inf :: Expr
inf = K Inf



-- | Simplify a property, if possible.
crySimplify :: Prop -> Prop
crySimplify p = last (p : crySimpSteps p)

-- | List the simplification steps for a property.
crySimpSteps :: Prop -> [Prop]
crySimpSteps = unfoldr (fmap dup . crySimpStep)
  where dup x = (x,x)

-- | A single simplification step.
crySimpStep :: Prop -> Maybe Prop
crySimpStep prop =
  case prop of

    Fin x     -> cryIsFin x   -- Fin only on variables.

    x :== y   -> cryIsEq x y
    x :>  y   -> Just (cryIsGt x y)

    x :>= y   ->
      case (x,y) of
        (K (Nat 0), _) -> Just (y :== zero)
        (K Inf, _)     -> Just PTrue
        (_, K Inf)     -> Just (x :== inf)
        _              -> Just (x :== y :|| x :> y)

    x :==: y ->
      case (x,y) of
        (K a, K b)     -> Just (if a == b then PTrue else PFalse)
        (K (Nat 0), _) -> cryIs0 True y
        (_, K (Nat 0)) -> cryIs0 True x
        _ -> bin (:==:) x y

    x :>: y ->
      case x of
        K (Nat 0)   -> Just PFalse
        K (Nat 1)   -> cryIs0 True y
        _           -> bin (:>:) x y

    p :&& q ->
      case cryAnd p q of
        Just r  -> Just r
        Nothing ->
          case crySimpStep p of
            Just p' -> Just (p' :&& q)
            Nothing ->
              case crySimpStep q of
                Just q' -> Just (p :&& q')
                Nothing -> Nothing

    p :|| q ->
      case cryOr p q of
        Just r  -> Just r
        Nothing ->
          case crySimpStep p of
            Just p' -> Just (p' :|| q)
            Nothing ->
              case crySimpStep q of
                Just q' -> Just (p :|| q')
                Nothing -> Nothing

    Not p -> case cryNot p of
               Just r -> Just r
               Nothing ->
                 case crySimpStep p of
                   Just p' -> Just (Not p')
                   Nothing -> Nothing

    PFalse  -> Nothing
    PTrue   -> Nothing

  where
  bin op x y =
    case crySimpExpr x of
      Just x' -> Just (op x' y)
      _ -> case crySimpExpr y of
             Just y' -> Just (op x y')
             Nothing -> Nothing





-- | Simplification of ':&&'.
-- XXX: Add propagation of `let x = t` where x is not in `fvs t`.
cryAnd :: Prop -> Prop -> Maybe Prop
cryAnd p q =
  case p of
    PTrue       -> Just q
    PFalse      -> Just PFalse
    p1 :&& p2   -> Just (p1 :&& (p2 :&& q))

    Not (Fin (Var x))
      | Just q' <- cryKnownFin x False q -> Just (p :&& q')

    Fin (Var x)
      | Just q' <- cryKnownFin x True q -> Just (p :&& q')

    _ -> case q of
           PTrue  -> Just p
           PFalse -> Just PFalse
           _      -> Nothing


cryKnownFin :: Name -> Bool -> Prop -> Maybe Prop
cryKnownFin x isFin prop =
  case prop of
    Fin (Var x') | x == x' -> Just (if isFin then PTrue else PFalse)

    p :&& q -> case (cryKnownFin x isFin p, cryKnownFin x isFin q) of
                 (Nothing, Nothing) -> Nothing
                 (mbP, mbQ) -> Just (fromMaybe p mbP :&& fromMaybe q mbQ)

    p :|| q -> case (cryKnownFin x isFin p, cryKnownFin x isFin q) of
                 (Nothing, Nothing) -> Nothing
                 (mbP, mbQ) -> Just (fromMaybe p mbP :|| fromMaybe q mbQ)

    Not p   -> case cryKnownFin x isFin p of
                 Nothing -> Nothing
                 Just p' -> Just (Not p')

    _ -> Nothing




-- | Simplification of ':||'.
cryOr :: Prop -> Prop -> Maybe Prop
cryOr p q =
  case p of
    PTrue  -> Just PTrue
    PFalse -> Just q
    _ -> case q of
           PTrue  -> Just PTrue
           PFalse -> Just p
           _      -> Nothing


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




-- | Generate a property ensuring that the expression is well-defined.
-- This might be a bit too strict.  For example, we reject things like
-- @max inf (0 - 1)@, which one might think would simplify to @inf@.
cryDefined :: Expr -> Prop
cryDefined expr =
  case expr of
    K _       -> PTrue
    Var _     -> PTrue    -- Variables are always assumed to be OK.
                      -- The idea is that we are going to check for
                      -- defined-ness before instantiating variables.
    x :+ y    -> cryDefined x :&& cryDefined y
    x :- y    -> cryDefined x :&& cryDefined y :&&
                 Fin y :&& x :>= y
    x :* y    -> cryDefined x :&& cryDefined y
    Div x y   -> cryDefined x :&& cryDefined y :&&
                 Fin x :&& Not (y :== zero)
    Mod x y   -> cryDefined x :&& cryDefined y :&&
                 Fin x :&& Not (y :== zero)
    x :^^ y   -> cryDefined x :&& cryDefined y
    Min x y   -> cryDefined x :&& cryDefined y
    Max x y   -> cryDefined x :&& cryDefined y
    Lg2 x     -> cryDefined x
    Width x   -> cryDefined x
    LenFromThen x y w ->
      cryDefined x :&& cryDefined y :&& cryDefined w :&&
      Fin x :&& Fin y :&& Fin w :&& Not (x :== y)
    LenFromThenTo x y z ->
      cryDefined x :&& cryDefined y :&& cryDefined z :&&
      Fin x :&& Fin y :&& Fin z :&& Not (x :== y)


-- | Simplificaiton for ':=='
cryIsEq :: Expr -> Expr -> Maybe Prop

cryIsEq (K m) (K n)   = Just (if m == n then PTrue else PFalse)

cryIsEq (K (Nat 0)) y = cryIs0 False y
cryIsEq x (K (Nat 0)) = cryIs0 False x

cryIsEq (K Inf) y     = Just (Not (Fin y))
cryIsEq x (K Inf)     = Just (Not (Fin x))
cryIsEq x y           = case crySimpExpr x of
                          Just x' -> Just (x' :== y)
                          Nothing ->
                            case crySimpExpr y of
                              Just y' -> Just (x :== y')
                              Nothing ->
                                Just ( Not (Fin x) :&& Not (Fin y)
                                   :|| Fin x :&& Fin y :&& x :==: y
                                     )



cryIsGt :: Expr -> Expr -> Prop
cryIsGt (K m) (K n)   = if m > n then PTrue else PFalse
cryIsGt x y           =
  case crySimpExpr x of
    Just x' -> x' :> y
    Nothing -> case crySimpExpr y of
                 Just y' -> x :> y'
                 Nothing -> Fin y :&& (x :== inf :|| Fin x :&& x :>: y)


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
      Impossible -> PFalse
      Return p   -> p
      If p t e   -> p :&& toProp t :|| Not p :&& toProp e



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
                           -- 0 ^^ inf,                  1 ^^ inf
           )

    Min t1 t2            -> Just (Fin t1 :|| Fin t2)
    Max t1 t2            -> Just (Fin t1 :&& Fin t2)
    Lg2 t1               -> Just (Fin t1)
    Width t1             -> Just (Fin t1)
    LenFromThen  _ _ _   -> Just PTrue
    LenFromThenTo  _ _ _ -> Just PTrue


-- | Simplify @t :== 0@ or @t :==: 0@.
-- Assumes defined input.
cryIs0 :: Bool -> Expr -> Maybe Prop
cryIs0 useFinite ty =
  case ty of
    K Inf               -> Just PFalse
    K (Nat n)           -> Just (if n == 0 then PTrue else PFalse)
    Var _               -> Nothing
    t1 :+ t2            -> Just (eq t1 zero :&& eq t2 zero)
    t1 :- t2            -> Just (eq t1 t2)
    t1 :* t2            -> Just (eq t1 zero :|| eq t2 zero)
    Div t1 t2           -> Just (gt t2 t1)
    Mod _ _             -> (`eq` zero) `fmap` crySimpExpr ty
                           -- or: Just (t2 `Divides` t1)
    t1 :^^ t2           -> Just (eq t1 zero :&& gt t2 zero)
    Min t1 t2           -> Just (eq t1 zero :|| eq t2 zero)
    Max t1 t2           -> Just (eq t1 zero :&& eq t2 zero)
    Lg2 t1              -> Just (eq t1 zero :|| eq t1 one)
    Width t1            -> Just (eq t1 zero)
    LenFromThen x y w   -> Just (eq w zero :|| gt x y)

    -- See `nLenFromThenTo` in 'Cryptol.TypeCheck.Solver.InfNat'
    LenFromThenTo x y z -> Just ( gt x y :&& gt z x
                              :|| gt y x :&& gt x z
                                )

  where
  eq x y = if useFinite then x :==: y else x :== y
  gt x y = if useFinite then x :>: y  else x :>  y



--------------------------------------------------------------------------------
-- Simplification of expressions
--------------------------------------------------------------------------------


-- | Make a simplification step, assuming the expression is well-formed.
crySimpExpr :: Expr -> Maybe Expr
crySimpExpr expr =
  case expr of
    K _                   -> Nothing
    Var _                 -> Nothing

    x :+ y ->
      case (x,y) of
        (K (Nat 0), _)    -> Just y
        (K Inf, _)        -> Just inf
        (_, K (Nat 0))    -> Just x
        (_, K Inf)        -> Just inf
        (K a, K b)        -> Just (K (IN.nAdd a b))
        _                 -> bin (:+) x y

    x :- y ->
      case (x,y) of
        (K (Nat 0), _)    -> Just zero
        (K Inf, _)        -> Just inf
        (_, K (Nat 0))    -> Just x
        (K a, K b)        -> K `fmap` IN.nSub a b
        _ | x == y        -> Just zero
        _                 -> bin (:-) x y

    x :* y ->
      case (x,y) of
        (K (Nat 0), _)    -> Just zero
        (K (Nat 1), _)    -> Just y
        (_, K (Nat 0))    -> Just zero
        (_, K (Nat 1))    -> Just x
        (K a, K b)        -> Just (K (IN.nMul a b))
        _                 -> bin (:*) x y

    Div x y ->
      case (x,y) of
        (K (Nat 0), _)    -> Just zero
        (_, K Inf)        -> Just zero
        (K a, K b)        -> K `fmap` IN.nDiv a b
        _ | x == y        -> Just one
        _                 -> bin Div x y

    Mod x y ->
      case (x,y) of
        (_, K Inf)        -> Just x
        (_, K (Nat 1))    -> Just zero
        (K a, K b)        -> K `fmap` IN.nMod a b
        _                 -> bin Mod x y

    x :^^ y ->
      case (x,y) of
        (_, K (Nat 0))    -> Just one
        (_, K (Nat 1))    -> Just x
        (K (Nat 1), _)    -> Just one
        (K a, K b)        -> Just (K (IN.nExp a b))
        _                 -> bin (:^^) x y

    Min x y ->
      case (x,y) of
        (K (Nat 0), _)    -> Just zero
        (K Inf, _)        -> Just y
        (_, K (Nat 0))    -> Just zero
        (_, K Inf)        -> Just x
        (K a, K b)        -> Just (K (IN.nMin a b))
        _ | x == y        -> Just x
        _                 -> bin Min x y

    Max x y ->
      case (x,y) of
        (K (Nat 0), _)    -> Just y
        (K Inf, _)        -> Just inf
        (_, K (Nat 0))    -> Just x
        (_, K Inf)        -> Just inf
        _ | x == y        -> Just x
        _                 -> bin Max x y

    Lg2 x ->
      case x of
        K a               -> Just (K (IN.nLg2 a))
        _                 -> Lg2 `fmap` crySimpExpr x


    Width x ->
      case x of
        K a               -> Just (K (IN.nWidth a))
        _                 -> Width `fmap` crySimpExpr x

    LenFromThen x y w ->
      case (x,y,w) of
        (K a, K b, K c)   -> K `fmap` IN.nLenFromThen a b c
        _                 -> three LenFromThen x y w

    LenFromThenTo x y z ->
      case (x,y,z) of
        (K a, K b, K c)   -> K `fmap` IN.nLenFromThenTo a b c
        _                 -> three LenFromThenTo x y z

  where

  bin op x y = case crySimpExpr x of
                 Just x' -> Just (op x' y)
                 Nothing -> case crySimpExpr y of
                              Just y' -> Just (op x y')
                              Nothing -> Nothing

  three op x y z =
    case crySimpExpr x of
      Just x' -> Just (op x' y z)
      Nothing ->
        case crySimpExpr y of
          Just y' -> Just (op x y' z)
          Nothing ->
            case crySimpExpr z of
              Just z' -> Just (op x y z')
              Nothing -> Nothing





--------------------------------------------------------------------------------
-- Eliminating the @inf@ constant form finite terms.
--------------------------------------------------------------------------------


data IfExpr a = If Prop (IfExpr a) (IfExpr a) | Return a | Impossible

instance Functor       IfExpr where fmap = liftM
instance A.Applicative IfExpr where pure = return; (<*>) = ap
instance Monad IfExpr where
  return  = Return
  fail _  = Impossible
  m >>= k = case m of
              Impossible -> Impossible
              Return a   -> k a
              If p t e   -> If p (t >>= k) (e >>= k)


ppIfExpr :: IfExpr Expr -> Doc
ppIfExpr expr =
  case expr of
    If p t e -> hang (text "if" <+> ppProp p) 2
              ( (text "then" <+> ppIfExpr t)  $$
                (text "else" <+> ppIfExpr e)
              )
    Return e    -> ppExpr e
    Impossible  -> text "<impossible>"



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
           _           -> return (x' :- y')

    Div x y ->
      do x' <- cryNoInf x
         y' <- cryNoInf y
         case (x', y') of
           (K Inf, _) -> Impossible
           (_, K Inf) -> return zero
           _          -> return (Div x' y')

    Mod x y ->
      do x' <- cryNoInf x
         y' <- cryNoInf y
         case (x',y) of
           (K Inf, _) -> Impossible
           (_, K Inf) -> return x'
           _          -> return (Mod x' y')

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
         _             -> return (f x' y' z')

  mkIf p t e = case crySimplify p of
                 PTrue  -> t
                 PFalse -> e
                 p'     -> If p' t e





--------------------------------------------------------------------------------
-- Pretty Printing
--------------------------------------------------------------------------------

-- | Pretty print a top-level property.
ppProp :: Prop -> Doc
ppProp = ppPropPrec 0

-- | Pretty print a proposition, in the given precedence context.
ppPropPrec :: Int -> Prop -> Doc
ppPropPrec prec prop =
  case prop of
    Fin x     -> fun "fin" ppExprPrec x
    x :== y   -> bin "==" 4 1 1 ppExprPrec x y
    x :>= y   -> bin ">=" 4 1 1 ppExprPrec x y
    x :> y    -> bin ">"  4 1 1 ppExprPrec x y

    x :==: y  -> bin "==#" 4 1 1 ppExprPrec x y
    x :>: y   -> bin ">#"  4 1 1 ppExprPrec x y

    p :&& q   -> bin "&&" 3 1 0 ppPropPrec p q
    p :|| q   -> bin "||" 2 1 0 ppPropPrec p q
    Not p     -> fun "not" ppPropPrec p
    PTrue     -> text "True"
    PFalse    -> text "False"

  where
  wrap p d = if prec > p then parens d else d

  fun f how x = wrap 10 (text f <+> how 11 x)

  bin op opP lMod rMod how x y =
    wrap opP (sep [ how (opP + lMod) x, text op, how (opP + rMod) y ])


-- | Pretty print an expression at the top level.
ppExpr :: Expr -> Doc
ppExpr = ppExprPrec 0

-- | Pretty print an expression, in the given precedence context.
ppExprPrec :: Int -> Expr -> Doc
ppExprPrec prec expr =
  case expr of
    K Inf               -> text "inf"
    K (Nat n)           -> integer n
    Var (Name x)        -> text (names !! x)
    x :+ y              -> bin "+" 6 0 1 x y
    x :- y              -> bin "-" 6 0 1 x y
    x :* y              -> bin "*" 7 0 1 x y
    Div x y             -> fun "div" [x,y]
    Mod x y             -> fun "mod" [x,y]
    x :^^ y             -> bin "*" 8 1 0 x y
    Min x y             -> fun "min" [x,y]
    Max x y             -> fun "max" [x,y]
    Lg2 x               -> fun "lg2" [x]
    Width x             -> fun "width" [x]
    LenFromThen x y w   -> fun "lenFromThen" [x,y,w]
    LenFromThenTo x y z -> fun "lenFromThenTo" [x,y,z]

  where
  wrap p d = if prec > p then parens d else d

  fun f xs = wrap 10 (text f <+> sep (map (ppExprPrec 11) xs))

  bin op opP lMod rMod x y =
    wrap opP
      (ppExprPrec (opP + lMod) x <+> text op <+> ppExprPrec (opP + rMod) y)


-- | An infinite list of names, for pretty prinitng.
names :: [String]
names  = concatMap gen [ 0 :: Integer .. ]
  where
  gen x  = [ a : suff x | a <- [ 'a' .. 'z' ] ]

  suff 0 = ""
  suff x = show x
