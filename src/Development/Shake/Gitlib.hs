{-# LANGUAGE OverloadedStrings, DeriveDataTypeable, GeneralizedNewtypeDeriving, MultiParamTypeClasses, FlexibleInstances #-}
module Development.Shake.Gitlib
    ( defaultRuleGitLib
    , getGitReference
    , getGitContents
    , doesGitFileExist
    , readGitFile
    , isGitAncestor
    ) where

import System.IO
import qualified Data.ByteString.Char8 as BS
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Data.Functor
import Data.Maybe
import System.Exit


import Development.Shake
import Development.Shake.Rule
import Development.Shake.Classes

import Data.Text.Binary

import Git
import Git.Libgit2
import Data.Tagged

type RepoPath = FilePath

newtype GetGitReferenceQ = GetGitReferenceQ (RepoPath, RefName)
    deriving (Typeable,Eq,Hashable,Binary,NFData,Show)

newtype GitSHA = GitSHA T.Text
    deriving (Typeable,Eq,Hashable,Binary,NFData,Show)

newtype GetGitFileRefQ = GetGitFileRefQ (RepoPath, RefName, FilePath)
    deriving (Typeable,Eq,Hashable,Binary,NFData,Show)

newtype IsGitAncestorQ = IsGitAncestorQ (RepoPath, RefName, RefName)
    deriving (Typeable,Eq,Hashable,Binary,NFData,Show)

instance Rule GetGitReferenceQ GitSHA where
    storedValue _ (GetGitReferenceQ (repoPath, name)) = do
        Just . GitSHA <$> getGitReference' repoPath name

instance Rule GetGitFileRefQ (Maybe T.Text) where
    storedValue _ (GetGitFileRefQ (repoPath, name, filename)) = do
        ref' <- getGitReference' repoPath name
        Just <$> getGitFileRef' repoPath ref' filename

instance Rule IsGitAncestorQ Bool where
    storedValue _ (IsGitAncestorQ (repoPath, ancestor, child)) = do
        Just <$> isGitAncestor' repoPath ancestor child

getGitReference :: RepoPath -> String -> Action String
getGitReference repoPath refName = do
    GitSHA ref' <- apply1 $ GetGitReferenceQ (repoPath, T.pack refName)
    return $ T.unpack ref'

isGitAncestor :: RepoPath -> String -> String -> Action Bool
isGitAncestor repoPath ancName childName = do
    apply1 $ IsGitAncestorQ (repoPath, T.pack ancName, T.pack childName)

getGitContents :: RepoPath -> Action [FilePath]
getGitContents repoPath = do
    GitSHA ref' <- apply1 $ GetGitReferenceQ (repoPath, "HEAD")
    liftIO $ withRepository lgFactory repoPath $ do
        ref <- parseOid ref'
        commit <- lookupCommit (Tagged ref)
        tree <- lookupTree (commitTree commit)
        entries <- listTreeEntries tree
        return $ map (BS.unpack . fst) entries

-- Will also look through annotated tags
getGitReference' :: RepoPath -> RefName -> IO T.Text
{- This fails (https://github.com/jwiegley/gitlib/issues/49), so use command
 - line git instead.
getGitReference' repoPath refName = do
    withRepository lgFactory repoPath $ do
        Just ref <- resolveReference refName
        o <- lookupObject ref
        r <- case o of
            TagObj t -> do
                return $ renderObjOid $ tagCommit t
            _ -> return $ renderOid ref
        return $ renderOid ref
-}
getGitReference' repoPath refName = do
    T.pack . concat . lines . fromStdout <$> cmd ["git", "-C", repoPath, "rev-parse", T.unpack refName++"^{commit}"]

isGitAncestor' :: RepoPath -> RefName -> RefName -> IO Bool
-- Easier using git
isGitAncestor' repoPath ancName childName = do
    Exit c <- cmd ["git", "-C", repoPath, "merge-base", "--is-ancestor", T.unpack ancName, T.unpack childName]
    return (c == ExitSuccess)

getGitFileRef' :: RepoPath -> T.Text -> FilePath -> IO (Maybe T.Text)
getGitFileRef' repoPath ref' fn = do
    withRepository lgFactory repoPath $ do
        ref <- parseOid ref'
        commit <- lookupCommit (Tagged ref)
        tree <- lookupTree (commitTree commit)
        entry <- treeEntry tree (BS.pack fn)
        case entry of
            Just (BlobEntry ref _) -> return $ Just $ renderObjOid ref
            _ -> return Nothing

doesGitFileExist :: RepoPath -> FilePath -> Action Bool
doesGitFileExist repoPath fn = do
    res <- apply1 $ GetGitFileRefQ (repoPath, "HEAD", fn)
    return $ isJust (res :: Maybe T.Text)

readGitFile :: FilePath -> FilePath -> Action BS.ByteString
readGitFile repoPath fn = do
    res <- apply1 $ GetGitFileRefQ (repoPath, "HEAD", fn)
    case res of
        Nothing -> fail "readGitFile: File does not exist"
        Just ref' -> liftIO $ withRepository lgFactory repoPath $ do
            ref <- parseOid ref'
            catBlob (Tagged ref)

defaultRuleGitLib :: Rules ()
defaultRuleGitLib = do
    rule $ \(GetGitReferenceQ (repoPath, refName)) -> Just $ liftIO $
        GitSHA <$> getGitReference' repoPath refName
    rule $ \(GetGitFileRefQ (repoPath, refName, fn)) -> Just $ do
        GitSHA ref' <- apply1 $ GetGitReferenceQ (repoPath, "HEAD")
        liftIO $ getGitFileRef' repoPath ref' fn
    rule $ \(IsGitAncestorQ (repoPath, ancName, childName)) -> Just $ liftIO $
        isGitAncestor' repoPath ancName childName

