#!/usr/bin/env bash

project_root() {
	cd "$(dirname "${BASH_SOURCE[0]}")/.." || return
	pwd
}
