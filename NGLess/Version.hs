{- Copyright 2013-2017 NGLess Authors
 - License: MIT
 -}
{-# LANGUAGE TemplateHaskell, CPP #-}
module Version
    ( versionStr
    , compilationDateStr
    , dateStr
    , embeddedStr
    , gitHashStr
    ) where

import Development.GitRev (gitHash)

versionStr :: String
versionStr = "0.5+git"

dateStr :: String
dateStr = "unreleased"

gitHashStr :: String
gitHashStr = $(gitHash)

embeddedStr :: String
#ifdef NO_EMBED_SAMTOOLS_BWA
embeddedStr = "No"
#else
embeddedStr = "Yes"
#endif

compilationDateStr :: String
compilationDateStr = __DATE__
