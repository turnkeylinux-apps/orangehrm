COMMON_CONF = apache-credit

CREDIT_ANCHORTEXT = OrangeHRM Appliance
CREDIT_LOCATION = ~ "^/(?!(.*symfony))"

include $(FAB_PATH)/common/mk/turnkey/lamp.mk
include $(FAB_PATH)/common/mk/turnkey.mk
