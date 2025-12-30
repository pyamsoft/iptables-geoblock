# The GPLv2 License
#
#   Copyright (C) 2025 pyamsoft
#
#   This program is free software; you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License along
#   with this program; if not, write to the Free Software Foundation, Inc.,
#   51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

NAME=iptables-geoblock

# Certain system files will only properly work situated at /usr
PREFIX?=/usr
SYSTEM_PREFIX=/usr

DOC_INSTALL_SRC="README.md"
LICENSE_INSTALL_SRC="LICENSE"

SCRIPT_INSTALL_DIR="$(DESTDIR)/$(PREFIX)/bin"
DOC_INSTALL_TARGET="$(DESTDIR)/$(PREFIX)/share/doc/$(NAME)/README.md"
LICENSE_INSTALL_TARGET="$(DESTDIR)/$(PREFIX)/share/doc/$(NAME)/LICENSE"
SYSTEMD_DIR="$(DESTDIR)/$(SYSTEM_PREFIX)/lib/systemd/system/"

.PHONY: all install uninstall \
	install-doc install-license install-script install-systemd \
	uninstall-script uninstall-doc uninstall-license uninstall-systemd

all:
	@echo "Targets"
	@echo " install uninstall"
	@echo $(TARGET)

install:
	@echo "Installing..."
	@mkdir -p "$(SYSTEMD_DIR)"
	@mkdir -p "$(SCRIPT_INSTALL_DIR)"
	@mkdir -p "$(shell dirname $(DOC_INSTALL_TARGET))"
	@$(MAKE) install-script
	@$(MAKE) install-systemd
	@$(MAKE) install-doc
	@$(MAKE) install-license

install-script:
	@echo "  INSTALL  iptables-geoblock update-geoblock"
	@install -Dm 755 "iptables-geoblock" "$(SCRIPT_INSTALL_DIR)/iptables-geoblock"
	@install -Dm 755 "update-geoblock" "$(SCRIPT_INSTALL_DIR)/update-geoblock"

install-doc:
	@echo "  INSTALL  $(DOC_INSTALL_TARGET)"
	@install -Dm 644 "$(DOC_INSTALL_SRC)" "$(DOC_INSTALL_TARGET)"

install-license:
	@echo "  INSTALL  $(LICENSE_INSTALL_TARGET)"
	@install -Dm 644 "$(LICENSE_INSTALL_SRC)" "$(LICENSE_INSTALL_TARGET)"

install-systemd:
	@echo "  INSTALL  systemd services"
	@install -Dm 644 "systemd/iptables-geoblock@.service" "$(SYSTEMD_DIR)/iptables-geoblock@.service"
	@install -Dm 644 "systemd/update-geoblock.service" "$(SYSTEMD_DIR)/update-geoblock.service"
	@sed -i "s|%PREFIX%|$(PREFIX)|" "$(SYSTEMD_DIR)/iptables-geoblock@.service"
	@sed -i "s|%PREFIX%|$(PREFIX)|" "$(SYSTEMD_DIR)/update-geoblock.service"
	
uninstall:
	@echo "Uninstalling..."
	@$(MAKE) uninstall-script
	@$(MAKE) uninstall-systemd
	@$(MAKE) uninstall-doc
	@$(MAKE) uninstall-license

uninstall-script:
	@echo "  UNINSTALL  iptables-geoblock update-geoblock"
	@rm -f "$(SCRIPT_INSTALL_DIR)/iptables-geoblock"
	@rm -f "$(SCRIPT_INSTALL_DIR)/update-geoblock"

uninstall-doc:
	@echo "  UNINSTALL  $(DOC_INSTALL_TARGET)"
	@rm -f "$(DOC_INSTALL_TARGET)"
	@rmdir --ignore-fail-on-non-empty "$(shell dirname $(DOC_INSTALL_TARGET))"

uninstall-license:
	@echo "  UNINSTALL  $(LICENSE_INSTALL_TARGET)"
	@rm -f "$(LICENSE_INSTALL_TARGET)"
	@rmdir --ignore-fail-on-non-empty "$(shell dirname $(LICENSE_INSTALL_TARGET))"

uninstall-systemd:
	@echo "  UNINSTALL  systemd services"
	@rm -f "$(SYSTEMD_DIR)/iptables-geoblock@.service"
	@rm -f "$(SYSTEMD_DIR)/update-geoblock.service"
