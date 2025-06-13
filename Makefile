# SPDX-FileCopyrightText: © 2025 m-click.aero GmbH <https://m-click.aero>
# SPDX-License-Identifier: Apache-2.0

.PHONY: default
default: check

NIXFILES = $(wildcard *.nix */*.nix)

.PHONY: check
check:
	nixfmt -s -c $(NIXFILES)

.PHONY: promote
promote:
	nixfmt -s $(NIXFILES)
