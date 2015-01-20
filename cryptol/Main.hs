-- |
-- Module      :  $Header$
-- Copyright   :  (c) 2013-2014 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com
-- Stability   :  provisional
-- Portability :  portable

{-# LANGUAGE CPP #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Main where

import OptParser
import REPL.Command (loadCmd,loadPrelude)
import REPL.Haskeline
import REPL.Monad (REPL,setREPLTitle,io,DotCryptol(..),
                   prependSearchPath,setSearchPath)
import REPL.Logo
import qualified REPL.Monad as REPL
import Paths_cryptol (version)

import Cryptol.Version (commitHash, commitBranch, commitDirty)
import Data.Version (showVersion)
import Cryptol.Utils.PP(pp)
import Data.Monoid (mconcat)
import System.Environment (getArgs, getProgName, lookupEnv)
import System.Exit (exitFailure)
import System.FilePath (splitSearchPath)
import System.Console.GetOpt
    (OptDescr(..),ArgOrder(..),ArgDescr(..),getOpt,usageInfo)

data Options = Options
  { optLoad            :: [FilePath]
  , optVersion         :: Bool
  , optHelp            :: Bool
  , optBatch           :: Maybe FilePath
  , optDotCryptol      :: DotCryptol
  , optCryptolPathOnly :: Bool
  } deriving (Show)

defaultOptions :: Options
defaultOptions  = Options
  { optLoad            = []
  , optVersion         = False
  , optHelp            = False
  , optBatch           = Nothing
  , optDotCryptol      = DotCDefault
  , optCryptolPathOnly = False
  }

options :: [OptDescr (OptParser Options)]
options  =
  [ Option "b" ["batch"] (ReqArg setBatchScript "FILE")
    "run the script provided and exit"

  , Option "v" ["version"] (NoArg setVersion)
    "display version number"

  , Option "h" ["help"] (NoArg setHelp)
    "display this message"

  , Option ""  ["ignore-dot-cryptol"] (NoArg setDotCDisabled)
    "disable reading of .cryptol files"

  , Option ""  ["cryptol-script"] (ReqArg addDotC "FILE")
    "read additional .cryptol files"

  , Option ""  ["cryptolpath-only"] (NoArg setCryptolPathOnly)
    "only look for .cry files in CRYPTOLPATH; don't use built-in locations"
  ]

-- | Set a single file to be loaded.  This should be extended in the future, if
-- we ever plan to allow multiple files to be loaded at the same time.
addFile :: String -> OptParser Options
addFile path = modify $ \ opts -> opts { optLoad = [ path ] }

-- | Set a batch script to be run.
setBatchScript :: String -> OptParser Options
setBatchScript path = modify $ \ opts -> opts { optBatch = Just path }

-- | Signal that version should be displayed.
setVersion :: OptParser Options
setVersion  = modify $ \ opts -> opts { optVersion = True }

-- | Signal that help should be displayed.
setHelp :: OptParser Options
setHelp  = modify $ \ opts -> opts { optHelp = True }

-- | Disable .cryptol files entirely
setDotCDisabled :: OptParser Options
setDotCDisabled  = modify $ \ opts -> opts { optDotCryptol = DotCDisabled }

-- | Add another file to read as a .cryptol file, unless .cryptol
-- files have been disabled
addDotC :: String -> OptParser Options
addDotC path = modify $ \ opts ->
  case optDotCryptol opts of
    DotCDefault  -> opts { optDotCryptol = DotCFiles [path] }
    DotCDisabled -> opts
    DotCFiles xs -> opts { optDotCryptol = DotCFiles (path:xs) }

setCryptolPathOnly :: OptParser Options
setCryptolPathOnly  = modify $ \opts -> opts { optCryptolPathOnly = True }

-- | Parse arguments.
parseArgs :: [String] -> Either [String] Options
parseArgs args = case getOpt (ReturnInOrder addFile) options args of
  (ps,[],[]) -> runOptParser defaultOptions (mconcat ps)
  (_,_,errs) -> Left errs

displayVersion :: IO ()
displayVersion = do
    let ver = showVersion version
    putStrLn ("Cryptol " ++ ver)
    putStrLn ("Git commit " ++ commitHash)
    putStrLn ("    branch " ++ commitBranch ++ dirtyLab)
      where
      dirtyLab | commitDirty = " (non-committed files present during build)"
               | otherwise   = ""

displayHelp :: [String] -> IO ()
displayHelp errs = do
  prog <- getProgName
  let banner = "Usage: " ++ prog ++ " [OPTIONS]"
  putStrLn (usageInfo (concat (errs ++ [banner])) options)

main :: IO ()
main  = do
  args <- getArgs
  case parseArgs args of

    Left errs -> do
      displayHelp errs
      exitFailure

    Right opts
      | optHelp opts    -> displayHelp []
      | optVersion opts -> displayVersion
      | otherwise       -> repl (optDotCryptol opts)
                                (optBatch opts)
                                (setupREPL opts)

setupREPL :: Options -> REPL ()
setupREPL opts = do
  displayLogo True
  setREPLTitle
  mCryptolPath <- io $ lookupEnv "CRYPTOLPATH"
  case mCryptolPath of
    Nothing -> return ()
    Just path | optCryptolPathOnly opts -> setSearchPath path'
              | otherwise               -> prependSearchPath path'
#if defined(mingw32_HOST_OS) || defined(__MINGW32__)
      -- Windows paths search from end to beginning
      where path' = reverse (splitSearchPath path)
#else
      where path' = splitSearchPath path
#endif
  case optLoad opts of
    []  -> loadPrelude `REPL.catch` \x -> io $ print $ pp x
    [l] -> loadCmd l `REPL.catch` \x -> io $ print $ pp x
    _   -> io $ putStrLn "Only one file may be loaded at the command line."
