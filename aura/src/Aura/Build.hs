{-# LANGUAGE OverloadedStrings #-}

{-

Copyright 2012 - 2018 Colin Woodbury <colin@fosskers.ca>

This file is part of Aura.

Aura is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

Aura is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with Aura.  If not, see <http://www.gnu.org/licenses/>.

-}

-- Agnostically builds packages. They can be either AUR or ABS.

module Aura.Build
  ( installPkgFiles
  , buildPackages
  ) where

import           Aura.Core
import           Aura.Languages
import           Aura.MakePkg
import           Aura.Monad.Aura
import           Aura.Pacman (pacman)
import           Aura.Settings.Base
import           Aura.Utils
import           BasePrelude hiding (FilePath)
import           Data.Bitraversable (bitraverse)
import qualified Data.Text as T
import           Filesystem.Path (filename)
import           Shelly
import           Utilities

---

srcPkgStore :: FilePath
srcPkgStore = "/var/cache/aura/src"

-- | Expects files like: /var/cache/pacman/pkg/*.pkg.tar.xz
installPkgFiles :: [T.Text] -> [T.Text] -> Aura ()
installPkgFiles _ []          = pure ()
installPkgFiles pacOpts files = checkDBLock *> pacman (["-U"] <> pacOpts <> files)

-- | All building occurs within temp directories in the package cache,
-- or in a location specified by the user with flags.
buildPackages :: [Buildable] -> Aura [FilePath]
buildPackages = fmap concat . traverse build

-- | Handles the building of Packages. Fails nicely.
-- Assumed: All dependencies are already installed.
build :: Buildable -> Aura [FilePath]
build p = do
  ss     <- ask
  notify $ buildPackages_1 (T.unpack $ baseNameOf p) (langOf ss)
  result <- shelly $ build' ss p
  case result of
    Left err -> buildFail p err
    Right fs -> pure fs

-- | Should never throw a Shelly Exception. In theory all errors
-- will come back via the @Language -> String@ function.
build' :: Settings -> Buildable -> Sh (Either (Language -> String) [FilePath])
build' ss p = do
  cd $ buildPathOf ss
  withTmpDir $ \curr -> do
    cd curr
    getBuildScripts p user >>= either (pure . Left) f
  where user = buildUserOf ss
        f bs = do
          cd bs
          overwritePkgbuild ss p
          pNames <- makepkg ss user
          bitraverse pure g pNames
        g pns = do
          paths <- traverse (moveToCachePath ss) pns
          when (keepSource ss) $ makepkgSource user >>= traverse_ moveToSourcePath
          pure paths

getBuildScripts :: Buildable -> User -> Sh (Either (Language -> String) FilePath)
getBuildScripts pkg user = do
  currDir <- toTextIgnore <$> pwd
  scriptsDir <- chown user currDir [] *> liftIO (buildScripts pkg (T.unpack currDir))
  case scriptsDir of
    Nothing -> pure . Left . buildFail_7 . T.unpack $ baseNameOf pkg
    Just sd -> do
      let sd' = T.pack sd
      chown user sd' ["-R"]
      pure . Right $ fromText sd'

-- | The user may have edited the original PKGBUILD. If they have, we need to
-- overwrite what's been downloaded before calling `makepkg`.
overwritePkgbuild :: Settings -> Buildable -> Sh ()
overwritePkgbuild ss p = when (mayHotEdit ss || useCustomizepkg ss) $
  writefile "PKGBUILD" $ pkgbuildOf p

-- | Inform the user that building failed. Ask them if they want to
-- continue installing previous packages that built successfully.
buildFail :: Buildable -> (Language -> String) -> Aura [a]
buildFail p err = do
  ss <- ask
  scold $ buildFail_1 (T.unpack $ baseNameOf p) (langOf ss)
  scold . err $ langOf ss
  response <- optionalPrompt ss buildFail_6
  if response
     then pure []
     else scoldAndFail buildFail_5

-- | If the user wasn't running Aura with `-x`, then this will
-- show them the suppressed makepkg output.

-- displayBuildErrors :: Error -> Aura ()
-- displayBuildErrors errors = ask >>= \ss -> when (suppressMakepkg ss == BeQuiet) $ do
--   putStrA red (displayBuildErrors_1 $ langOf ss)
--   liftIO (timedMessage 1000000 ["3.. ", "2.. ", "1..\n"] *> putStrLn errors)

-- | Moves a file to the pacman package cache and returns its location.
moveToCachePath :: Settings -> FilePath -> Sh FilePath
moveToCachePath ss p = cp p newName $> newName
  where newName = cachePathOf ss </> filename p

-- | Moves a file to the aura src package cache and returns its location.
moveToSourcePath :: FilePath -> Sh FilePath
moveToSourcePath p = mv p newName $> newName
  where newName = srcPkgStore </> p
