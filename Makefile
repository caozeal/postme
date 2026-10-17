APP_NAME  := postme
CONFIG    ?= release
BUILD_DIR := build
APP_DIR   := $(BUILD_DIR)/$(APP_NAME).app

.PHONY: help build test app run open icon clean

help:
	@echo "make build   - 编译 release 产物"
	@echo "make test    - 跑逻辑层测试(swift test)"
	@echo "make app     - 编译并打包成 build/postme.app(含 ad-hoc 签名)"
	@echo "make run     - 开发期直接运行(debug,靠 AppDelegate 兜底激活)"
	@echo "make open    - 打包并用 LaunchServices 打开(菜单栏/聚焦最正常)"
	@echo "make icon    - 重新渲染应用图标(scripts/render_icon.swift)"
	@echo "make clean   - 清理构建产物"

build:
	swift build -c $(CONFIG)

icon:
	swift scripts/render_icon.swift
	iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

test:
	swift test

app:
	CONFIG=$(CONFIG) ./scripts/bundle.sh

run:
	swift run $(APP_NAME)

open: app
	open $(APP_DIR)

clean:
	swift package clean
	rm -rf $(BUILD_DIR)
