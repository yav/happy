-- -----------------------------------------------------------------------------
-- 
-- AbsSyn.hs, part of Alex
--
-- (c) Chris Dornan 1995-2000, Simon Marlow 2003
--
-- This module provides a concrete representation for regular expressions and
-- scanners.  Scanners are used for tokenising files in preparation for parsing.
--
-- ----------------------------------------------------------------------------}

module AbsSyn (
  Script,
  Code,
  Def(..),
  Scanner(..),
  RECtx(..),
  RExp(..),
  DFA(..), State(..), SNum, StartCode, Accept(..),
  encode_start_codes,
  Target(..)
  ) where

import CharSet
import Sort

import Data.FiniteMap
import Data.Maybe

infixl 4 :|
infixl 5 :%%

-- -----------------------------------------------------------------------------
-- Abstract Syntax for Alex scripts

type Script = [Def]

type Code = String

data Def
  = DefScanner Scanner
  | DefCode Code
  deriving Show

-- TODO: update this comment
--
-- A `Scanner' consists of an association list associating token names with
-- regular expressions with context.  The context may include a list of start
-- codes, some leading context to test the character immediately preceding the
-- token and trailing context to test the residual input after the token.
--  
-- The start codes consist of the names and numbers of the start codes;
-- initially the names only will be generated by the parser, the numbers being
-- allocated at a later stage.  Start codes become meaningful when scanners are
-- converted to DFAs; see the DFA section of the Scan module for details.

data Scanner = Scanner { scannerName   :: String,
			 scannerTokens :: [RECtx] }
  deriving Show

data RECtx = RECtx { reCtxStartCodes :: [(String,StartCode)],
		     reCtxPreCtx     :: Maybe CharSet,
		     reCtxRE	     :: RExp,
		     reCtxPostCtx    :: Maybe RExp,
		     reCtxCode	     :: Code
		   }

instance Show RECtx where
  showsPrec _ (RECtx scs _ r rctx code) = 
	showStarts scs . shows r . showRCtx rctx . showCode code

showCode code = showString " { " . showString code . showString " }"

showStarts [] = id
showStarts scs = shows scs

showRCtx Nothing = id
showRCtx (Just r) = ('\\':) . shows r

-- -----------------------------------------------------------------------------
-- DFAs

data DFA s a = DFA
  { dfa_start_states :: [s],
    dfa_states       :: FiniteMap s (State s a)
  }

data State s a = State [Accept a] (FiniteMap Char s)

type SNum = Int

data Accept a
  = Acc { accPrio       :: Int,
	  accAction     :: a,
	  accLeftCtx    :: Maybe CharSet,
	  accRightCtx   :: Maybe SNum
    }

type StartCode = Int

-- -----------------------------------------------------------------------------
-- Regular expressions

-- `RExp' provides an abstract syntax for regular expressions.  `Eps' will
-- match empty strings; `Ch p' matches strings containinng a single character
-- `c' if `p c' is true; `re1 :%% re2' matches a string if `re1' matches one of
-- its prefixes and `re2' matches the rest; `re1 :| re2' matches a string if
-- `re1' or `re2' matches it; `Star re', `Plus re' and `Ques re' can be
-- expressed in terms of the other operators.  See the definitions of `ARexp'
-- for a formal definition of the semantics of these operators.

data RExp 
  = Eps
  | Ch CharSet
  | RExp :%% RExp
  | RExp :| RExp
  | Star RExp
  | Plus RExp
  | Ques RExp	

instance Show RExp where
  showsPrec _ Eps = showString "()"
  showsPrec _ (Ch set) = showString "[..]"
  showsPrec _ (l :%% r)  = shows l . shows r
  showsPrec _ (l :| r)  = shows l . ('|':) . shows r
  showsPrec _ (Star r) = shows r . ('*':)
  showsPrec _ (Plus r) = shows r . ('+':)
  showsPrec _ (Ques r) = shows r . ('?':)

{------------------------------------------------------------------------------
			  Abstract Regular Expression
------------------------------------------------------------------------------}


-- This section contains demonstrations; it is not part of Alex.

{-
-- This function illustrates `ARexp'. It returns true if the string in its
-- argument is matched by the regular expression.

recognise:: RExp -> String -> Bool
recognise re inp = any (==len) (ap_ar (arexp re) inp)
	where
	len = length inp


-- `ARexp' provides an regular expressions in abstract format.  Here regular
-- expressions are represented by a function that takes the string to be
-- matched and returns the sizes of all the prefixes matched by the regular
-- expression (the list may contain duplicates).  Each of the `RExp' operators
-- are represented by similarly named functions over ARexp.  The `ap' function
-- takes an `ARExp', a string and returns the sizes of all the prefixes
-- matching that regular expression.  `arexp' converts an `RExp' to an `ARexp'.


arexp:: RExp -> ARexp
arexp Eps = eps_ar
arexp (Ch p) = ch_ar p
arexp (re :%% re') = arexp re `seq_ar` arexp re'
arexp (re :| re') = arexp re `bar_ar` arexp re'
arexp (Star re) = star_ar (arexp re)
arexp (Plus re) = plus_ar (arexp re)
arexp (Ques re) = ques_ar (arexp re)


star_ar:: ARexp -> ARexp
star_ar sc =  eps_ar `bar_ar` plus_ar sc

plus_ar:: ARexp -> ARexp
plus_ar sc = sc `seq_ar` star_ar sc

ques_ar:: ARexp -> ARexp
ques_ar sc = eps_ar `bar_ar` sc


-- Hugs abstract type definition -- not for GHC.

type ARexp = String -> [Int]
--	in ap_ar, eps_ar, ch_ar, seq_ar, bar_ar

ap_ar:: ARexp -> String -> [Int]
ap_ar sc = sc

eps_ar:: ARexp
eps_ar inp = [0]

ch_ar:: (Char->Bool) -> ARexp
ch_ar p "" = []
ch_ar p (c:rst) = if p c then [1] else []

seq_ar:: ARexp -> ARexp -> ARexp
seq_ar sc sc' inp = [n+m| n<-sc inp, m<-sc' (drop n inp)]

bar_ar:: ARexp -> ARexp -> ARexp 
bar_ar sc sc' inp = sc inp ++ sc' inp
-}

-- -----------------------------------------------------------------------------
-- Utils

-- Map the available start codes onto [1..]

encode_start_codes:: String -> Script -> (Script,[StartCode],ShowS)
encode_start_codes ind defs = (defs', 0 : map snd name_code_pairs, sc_hdr)
	where
	defs' = map do_scanner defs
		where do_scanner (DefCode c) = DefCode c
		      do_scanner (DefScanner s) = 
			DefScanner s{ scannerTokens = 
					map mk_re_ctx (scannerTokens s) }

	mk_re_ctx (RECtx scs lc re rc code)
	  = RECtx (map mk_sc scs) lc re rc code

	mk_sc (nm,_) = (nm, if nm=="0" then 0 
				       else fromJust (lookupFM code_map nm))

	sc_hdr tl =
		case name_code_pairs of
		  [] -> tl
		  (nm,_):rst -> "\n" ++ ind ++ nm ++ foldr f t rst
			where
			f (nm, _) t = "," ++ nm ++ t
			t = " :: Int\n" ++ foldr fmt_sc tl name_code_pairs
		where
		fmt_sc (nm,sc) t = ind ++ nm ++ " = " ++ show sc ++ "\n" ++ t

	code_map = listToFM name_code_pairs

	name_code_pairs = zip (nub' (<=) nms) [1..]

	nms = [nm | DefScanner scr <- defs,
		    RECtx{reCtxStartCodes = scs} <- scannerTokens scr,
		    (nm,_) <- scs, nm /= "0"]

-- -----------------------------------------------------------------------------
-- Code generation targets

data Target = GhcTarget | HaskellTarget

