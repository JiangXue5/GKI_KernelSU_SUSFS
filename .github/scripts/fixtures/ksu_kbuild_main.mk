# Verbatim excerpt of upstream's version block. MDIR is the one line
# from just above it that the block depends on.
MDIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

REPO_OWNER  := shirkneko
REPO_NAME   := SukiSU
REPO_BRANCH := main

VERSION_BASE    := 30000
VERSION_OFFSET  := 996

GIT_BIN  := /usr/bin/env PATH="$$PATH":/usr/bin:/usr/local/bin git
CURL_BIN := /usr/bin/env PATH="$$PATH":/usr/bin:/usr/local/bin curl

KSU_SRC := $(if $(filter $(srctree),$(src)),$(src),$(srctree)/$(src))
KSU_SRC := $(if $(wildcard $(KSU_SRC)/../.git),$(KSU_SRC),$(MDIR))

git_short_sha    = $(shell cd $(KSU_SRC) && $(GIT_BIN) rev-parse --short=8 HEAD 2>/dev/null)
git_branch       = $(if $(strip $(KSU_BUILD_REF)),$(KSU_BUILD_REF),$(shell cd $(KSU_SRC) && $(GIT_BIN) rev-parse --abbrev-ref HEAD 2>/dev/null))
git_commit_count = $(shell cd $(KSU_SRC) && { $(GIT_BIN) rev-list --count $(REPO_BRANCH) 2>/dev/null || $(GIT_BIN) rev-list --count origin/$(REPO_BRANCH) 2>/dev/null; })
git_latest_tag   = $(shell cd $(KSU_SRC) && $(GIT_BIN) describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null | sed 's/^v//')

$(shell cd $(KSU_SRC) 2>/dev/null && [ -f ../.git/shallow ] && $(GIT_BIN) fetch --unshallow 2>/dev/null)

RELEASE_API_BASE := https://git.zako.shirkneko.top:20004/api/v1/repos/$(REPO_OWNER)/$(REPO_NAME)
KSU_RELEASE_VER  := $(shell $(CURL_BIN) -s "$(RELEASE_API_BASE)/releases/latest" 2>/dev/null | grep -o '"tag_name":"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/^v//')
RELEASE_COMMITS  := $(shell $(CURL_BIN) -s -D - -o /dev/null "$(RELEASE_API_BASE)/commits?sha=$(REPO_BRANCH)&limit=1" 2>/dev/null | tr -d '\r' | sed -n 's/^[Xx]-[Tt]otal-[Cc]ount:[[:space:]]*\([0-9]*\).*/\1/p')
LOCAL_COUNT     := $(if $(RELEASE_COMMITS),$(RELEASE_COMMITS),$(git_commit_count))
KSU_VERSION     := $(if $(LOCAL_COUNT),$(shell expr $(VERSION_BASE) + $(LOCAL_COUNT) + $(VERSION_OFFSET)),$(VERSION_BASE))
VERSION_TAG     := $(or $(KSU_RELEASE_VER),$(git_latest_tag),3.0.0)
KSU_VERSION_FULL := $(if $(call git_short_sha),v$(VERSION_TAG)-$(call git_short_sha)@$(call git_branch),v$(VERSION_TAG)-$(REPO_NAME)-unknown@unknown)
$(info -- $(REPO_NAME) version: $(KSU_VERSION) [$(KSU_VERSION_FULL)])

ccflags-y += -DKSU_VERSION=$(KSU_VERSION)
ccflags-y += -DKSU_VERSION_FULL=\"$(KSU_VERSION_FULL)\"
