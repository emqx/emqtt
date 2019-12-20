PKG_VSN := $(shell git describe --tags --always)
# Keep this short to avoid bloating beam files with long file path info
TOPDIR := /tmp/emqx
SRCDIR := $(TOPDIR)/$(PKG_VSN)
DEB_VSN := $(PKG_VSN:v%=%)

ARCH := $(shell dpkg --print-architecture)
SOURCE_PKG := emqtt_$(DEB_VSN)_$(ARCH)
TARGET_PKG := emqtt-$(SYSTEM)-$(PKG_VSN)_$(ARCH)

.PHONY: all
all: prepare
	cp -r debian $(SRCDIR)/
	sed -i "s#<DATETIME>#$(shell date -u '+%a, %d %b %Y %T %z')#g" $(SRCDIR)/debian/changelog
	sed -i "s#<VERSION>#$(DEB_VSN)#g" $(SRCDIR)/debian/changelog
	cd $(SRCDIR) && dpkg-buildpackage -us -uc
	mkdir -p ../../_packages
	cp $(SRCDIR)/../$(SOURCE_PKG).deb ../../_packages/$(TARGET_PKG).deb

prepare:
	rm -rf $(SRCDIR)
	mkdir -p $(TOPDIR) $(SRCDIR)
	cp -r ../../_build/emqtt_pkg/rel/emqtt $(SRCDIR) 
