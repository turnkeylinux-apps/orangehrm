#!/bin/bash
set -Eeuo pipefail
umask 077

app_password=${TKL_TEST_APP_PASS:?TKL_TEST_APP_PASS is required}
db_password=${TKL_TEST_DB_PASS:?TKL_TEST_DB_PASS is required}
fixture=/var/lib/orangehrm-upgrade-fixture
archive=$fixture/orangehrm-5.8.1.zip
source=$fixture/orangehrm-5.8.1
base=https://localhost
cookie=$fixture/cookie
page=$fixture/page
headers=$fixture/headers
json=$fixture/json
employee=

report_error() {
    printf 'upgrade_test_failure line=%s status=%s command=%q\n' "$1" "$2" "$3" >&2
    exit "$2"
}
trap 'report_error "$LINENO" "$?" "$BASH_COMMAND"' ERR

login() {
    rm -f -- "$cookie"
    curl --insecure --fail --silent --show-error --location \
        "$base/web/index.php/auth/login" -c "$cookie" >"$page"
    token=$(sed -n 's/.*:token="&quot;\([^&]*\)&quot;".*/\1/p' "$page" | head -1)
    test -n "$token"
    curl --insecure --silent --show-error -D "$headers" -o "$page" \
        -b "$cookie" -c "$cookie" \
        --data-urlencode 'username=admin' \
        --data-urlencode "password=$app_password" \
        --data-urlencode "_token=$token" \
        "$base/web/index.php/auth/validate"
    grep -q '^HTTP/.* 302' "$headers"
    grep -qi '^location:.*dashboard' "$headers"
    curl --insecure --fail --silent --show-error -b "$cookie" \
        "$base/web/index.php/dashboard/index" >"$page"
    grep -q '<oxd-layout' "$page"
}

create_employee() {
    local employee_id=$1
    curl --insecure --fail --silent --show-error -b "$cookie" \
        -H 'Content-Type: application/json' \
        --data "{\"firstName\":\"Upgrade\",\"middleName\":\"\",\"lastName\":\"Fixture\",\"employeeId\":\"$employee_id\"}" \
        "$base/web/index.php/api/v2/pim/employees" >"$json"
    employee=$(jq -er '.data.empNumber' "$json")
}

read_employee() {
    curl --insecure --fail --silent --show-error -b "$cookie" \
        "$base/web/index.php/api/v2/pim/employees/$employee" >"$json"
    jq -e '.data.firstName == "Upgrade" and .data.lastName == "Fixture"' \
        "$json" >/dev/null
}

delete_employee() {
    curl --insecure --fail --silent --show-error -b "$cookie" \
        -H 'Content-Type: application/json' -X DELETE \
        --data "{\"ids\":[$employee]}" \
        "$base/web/index.php/api/v2/pim/employees" >"$json"
    jq -e --argjson employee "$employee" '.data | index($employee)' "$json" >/dev/null
    employee=
}

cleanup() {
    if [[ -n $employee ]]; then
        curl --insecure --silent --show-error -b "$cookie" \
            -H 'Content-Type: application/json' -X DELETE \
            --data "{\"ids\":[$employee]}" \
            "$base/web/index.php/api/v2/pim/employees" >/dev/null || true
    fi
}
trap cleanup EXIT

install -d -m 0700 "$fixture"
curl --fail --show-error --location \
    https://github.com/orangehrm/orangehrm/releases/download/v5.8.1/orangehrm-5.8.1.zip \
    --output "$archive"
echo '72ffc4bdc465a4072e51581288c6880f05a50eccf17e53202299b59992ffa465  '"$archive" | sha256sum -c -
(umask 022; unzip -q "$archive" -d "$fixture")
test "$(php -r "require '$source/src/lib/config/Config.php'; echo \\OrangeHRM\\Config\\Config::PRODUCT_VERSION;")" = 5.8.1

systemctl stop apache2.service
mv /var/www/orangehrm "$fixture/baseline-5.9"
mysql --user=root --password="$db_password" --execute='DROP DATABASE orangehrm; CREATE DATABASE orangehrm;'
cat >"$source/installer/cli_install_config.yaml" <<EOF
database:
  hostName: 127.0.0.1
  hostPort: 3306
  databaseName: orangehrm
  privilegedDatabaseUser: orangehrm
  privilegedDatabasePassword: $(php -r 'require "/var/lib/orangehrm-upgrade-fixture/baseline-5.9/lib/confs/Conf.php"; echo (new Conf())->getDbPass();')
  useSameDbUserForOrangeHRM: y
  orangehrmDatabaseUser: ~
  orangehrmDatabasePassword: ~
  isExistingDatabase: y
  enableDataEncryption: n

organization:
  name: TurnKeyLinux
  country: US

admin:
  adminUserName: admin
  adminPassword: $app_password
  adminEmployeeFirstName: Admin
  adminEmployeeLastName: istrator
  workEmail: admin@example.com
  contactNumber: ~
  registrationConsent: false

license:
  agree: y
EOF
php "$source/installer/cli_install.php"
mysql --user=root --password="$db_password" orangehrm --execute="
    UPDATE hs_hr_config SET value='off'
    WHERE name='auth.password_policy.enforce_password_strength';"
chown -R root:root "$source"
chown -R www-data:www-data "$source/lib/confs" "$source/src/cache" "$source/src/log"
printf '%s\n' 'Require all denied' >"$source/installer/.htaccess"
mv "$source" /var/www/orangehrm
runuser -u www-data -- test -r /var/www/orangehrm/web/index.php
cat >/usr/share/orangehrm/release <<EOF
version=5.8.1
url=https://github.com/orangehrm/orangehrm/releases/download/v5.8.1/orangehrm-5.8.1.zip
sha256=72ffc4bdc465a4072e51581288c6880f05a50eccf17e53202299b59992ffa465
EOF
systemctl start apache2.service

login
create_employee TKLUPGRADE
read_employee
orangehrm-update 5.9
test "$(php -r 'require "/var/www/orangehrm/src/lib/config/Config.php"; echo \OrangeHRM\Config\Config::PRODUCT_VERSION;')" = 5.9
grep -Fxq 'version=5.9' /usr/share/orangehrm/release
grep -Fxq 'sha256=f6e640f8b59e8d09f15edcd24ac3d42bb52dcc4839a7d83f964dd798bc793f79' \
    /usr/share/orangehrm/release
login
read_employee
delete_employee
create_employee TKLUPGRADEPOST
read_employee
delete_employee
trap - EXIT
rm -rf -- "$fixture"
