UNAME   := $(shell uname -s)
ARCH    := $(shell uname -m)

TESTS ?= issues regression renamer mono-binds
TEST_DIFF ?= meld

CABAL_FLAGS ?= -j

CABAL_EXE   := cabal
CABAL       := $(CABAL_EXE) $(CABAL_FLAGS)
CS          := ./.cabal-sandbox
CS_BIN      := $(CS)/bin

# Used only for windows, to find the right Program Files.
PROGRAM_FILES = Program\ Files\ \(x86\)
# Windows installer tools; assumes running on Cygwin and using WiX 3.8
WiX      := /cygdrive/c/${PROGRAM_FILES}/WiX\ Toolset\ v3.8
CANDLE   := ${WiX}/bin/candle.exe
HEAT     := ${WiX}/bin/heat.exe
LIGHT    := ${WiX}/bin/light.exe

REV         ?= $(shell git rev-parse --short=7 HEAD || echo "unknown")
VERSION     := $(shell grep -i ^Version cryptol.cabal | awk '{ print $$2}')
SYSTEM_DESC ?= ${UNAME}-${ARCH}_${REV}
PKG         := cryptol-${VERSION}-${SYSTEM_DESC}

# Windows-specific stuff
ifneq (,$(findstring _NT,${UNAME}))
  DIST := ${PKG}.msi
  EXE_EXT := .exe
  adjust-path = '$(shell cygpath -w $1)'
  PREFIX ?= /cygdrive/c/${PROGRAM_FILES}/Galois/Cryptol\ ${VERSION}
# on Windows we don't have to use the prefix in the staging directory
  PKG_PREFIX := ${PKG}
else
  DIST := ${PKG}.tar.gz ${PKG}.zip
  EXE_EXT :=
  adjust-path = '$1'
  PREFIX ?= /usr/local
  PKG_PREFIX := ${PKG}${PREFIX}
endif

CRYPTOL_EXE := ./dist/build/cryptol/cryptol${EXE_EXT}

.PHONY: all
all: ${CRYPTOL_EXE}

.PHONY: docs
docs:
	(cd docs; make)

.PHONY: dist
dist: ${DIST}

.PHONY: tarball
tarball: ${PKG}.tar.gz

.PHONY: zip
zip: ${PKG}.zip

.PHONY: msi
msi: ${PKG}.msi

.PHONY: deps
deps: ${CS}

# TODO: piece this apart a bit more; if right now if something fails
# during initial setup, you have to invoke this target again manually
${CS}:
	$(CABAL_EXE) sandbox init
	sh configure
	$(CABAL) install alex happy
	$(CABAL) install --only-dependencies

CRYPTOL_DEPS := \
  $(shell find src cryptol \
            \( -name \*.hs -or -name \*.x -or -name \*.y \) \
            -and \( -not -name \*\#\* \) -print) \
  $(shell find share/cryptol -name \*.cry)

print-%:
	@echo $* = $($*)

dist/setup-config: | ${CS}
	$(CABAL_EXE) configure                       \
          --prefix=$(call adjust-path,${PREFIX})     \
          --datadir=$(call adjust-path,${PREFIX})    \
          --datasubdir=$(call adjust-path,${PREFIX})

${CRYPTOL_EXE}: $(CRYPTOL_DEPS) | dist/setup-config
	$(CABAL) build

# ${CS_BIN}/cryptolnb: ${CS_BIN}/alex ${CS_BIN}/happy | ${CS}
# 	$(CABAL) install . -fnotebook

PKG_BIN       := ${PKG_PREFIX}/bin
PKG_SHARE     := ${PKG_PREFIX}/share
PKG_CRY       := ${PKG_SHARE}/cryptol
PKG_DOC       := ${PKG_SHARE}/doc/cryptol
PKG_EXAMPLES  := ${PKG_DOC}/examples
PKG_EXCONTRIB := ${PKG_EXAMPLES}/contrib

PKG_EXAMPLE_FILES := docs/ProgrammingCryptol/aes/AES.cry       \
                     docs/ProgrammingCryptol/enigma/Enigma.cry \
                     examples/DES.cry                          \
                     examples/Cipher.cry                       \
                     examples/DEStest.cry                      \
                     examples/Test.cry                         \
                     examples/SHA1.cry

PKG_EXCONTRIB_FILES := examples/contrib/mkrand.cry \
                       examples/contrib/RC4.cry    \
                       examples/contrib/simon.cry  \
                       examples/contrib/speck.cry

${PKG}: ${CRYPTOL_EXE}
	$(CABAL_EXE) copy --destdir=${PKG}
# don't want to bundle the cryptol library in the binary distribution
	rm -rf ${PKG_PREFIX}/lib
	mkdir -p ${PKG_CRY}
	mkdir -p ${PKG_DOC}
	mkdir -p ${PKG_EXAMPLES}
	mkdir -p ${PKG_EXCONTRIB}
	cp docs/*.md ${PKG_DOC}
	cp docs/*.pdf ${PKG_DOC}
	cp LICENSE ${PKG_DOC}
	for EXAMPLE in ${PKG_EXAMPLE_FILES}; do \
          cp $$EXAMPLE ${PKG_EXAMPLES}; done
	for EXAMPLE in ${PKG_EXCONTRIB_FILES}; do \
          cp $$EXAMPLE ${PKG_EXCONTRIB}; done

${PKG}.tar.gz: ${PKG}
	tar -czvf $@ $<

${PKG}.zip: ${PKG}
	zip -r $@ $<

${PKG}.msi: ${PKG} win32/cryptol.wxs
	${HEAT} dir ${PKG} -o allfiles.wxs -nologo -var var.pkg \
          -ag -wixvar -cg ALLFILES -srd -dr INSTALLDIR -sfrag
	${CANDLE} -ext WixUIExtension -ext WixUtilExtension     \
          -dversion=${VERSION} -dpkg=${PKG} win32/cryptol.wxs
	${CANDLE} -ext WixUIExtension -ext WixUtilExtension     \
          -dversion=${VERSION} -dpkg=${PKG} allfiles.wxs
	${LIGHT} -ext WixUIExtension -ext WixUtilExtension      \
	  -sval -o $@ cryptol.wixobj allfiles.wixobj
	rm -f allfiles.wxs
	rm -f *.wixobj
	rm -f *.wixpdb

${CS_BIN}/cryptol-test-runner: \
  ${PKG}                       \
  $(CURDIR)/tests/Main.hs      \
  $(CURDIR)/tests/cryptol-test-runner.cabal
	$(CABAL) install ./tests

.PHONY: test
test: ${CS_BIN}/cryptol-test-runner
	( cd tests &&                                                      \
	echo "Testing on $(UNAME)-$(ARCH)" &&                              \
	$(realpath $(CS_BIN)/cryptol-test-runner)                          \
	  $(foreach t,$(TESTS),-d $t)                                      \
	  -c $(call adjust-path,$(realpath ${PKG_BIN}/cryptol${EXE_EXT}))  \
	  -r output                                                        \
	  -T --hide-successes                                              \
	  -T --jxml=$(call adjust-path,$(CURDIR)/results.xml)              \
	  $(if $(TEST_DIFF),-p $(TEST_DIFF),)                              \
	)

# .PHONY: notebook
# notebook: ${CS_BIN}/cryptolnb
# 	cd notebook && ./notebook.sh

.PHONY: clean
clean:
	cabal clean
	rm -f src/GitRev.hs
	rm -f $(CS_BIN)/cryptol-test-suite
	rm -rf cryptol-${VERSION}*/
	rm -rf cryptol-${VERSION}*.tar.gz
	rm -rf cryptol-${VERSION}*.zip
	rm -rf cryptol-${VERSION}*.msi

.PHONY: squeaky
squeaky: clean
	-$(CABAL_EXE) sandbox delete
	(cd docs; make clean)
	rm -rf dist
	rm -rf tests/dist
