#!/bin/bash
set -Eeuo pipefail
umask 077

result=${TKL_TEST_RESULT:?TKL_TEST_RESULT is required}
app_password=${TKL_TEST_APP_PASS:?TKL_TEST_APP_PASS is required}
db_password=${TKL_TEST_DB_PASS:?TKL_TEST_DB_PASS is required}
base=https://localhost
login=$base/web/index.php/auth/login
cookie=/tmp/tkl-orangehrm-cookie.$$
page=/tmp/tkl-orangehrm-page.$$
headers=/tmp/tkl-orangehrm-headers.$$
json=/tmp/tkl-orangehrm-json.$$
policy=/tmp/tkl-orangehrm-policy.$$
adminer_cookie=/tmp/tkl-orangehrm-adminer-cookie.$$

report_error() {
    printf 'test_failure line=%s status=%s command=%q\n' "$1" "$2" "$3" >&2
    exit "$2"
}
trap 'report_error "$LINENO" "$?" "$BASH_COMMAND"' ERR

employee=
cleanup() {
    if [[ -n $employee ]]; then
        curl --insecure --silent --show-error -b "$cookie" \
            -H 'Content-Type: application/json' -X DELETE \
            --data "{\"ids\":[$employee]}" \
            "$base/web/index.php/api/v2/pim/employees" >/dev/null || true
    fi
    rm -f -- "$cookie" "$page" "$headers" "$json" "$policy" "$adminer_cookie"
}
trap cleanup EXIT

systemctl --quiet is-active apache2.service mariadb.service postfix.service multi-user.target
systemctl --quiet is-enabled apache2.service mariadb.service postfix.service
apache2ctl -t
apache2ctl -M 2>/dev/null | grep -F ' rewrite_module ' >/dev/null

orangehrm_version=$(php -r \
    'require "/var/www/orangehrm/src/lib/config/Config.php"; echo \OrangeHRM\Config\Config::PRODUCT_VERSION;')
test "$orangehrm_version" = 5.9
php_version=$(php -r 'echo PHP_MAJOR_VERSION, ".", PHP_MINOR_VERSION;')
test "$php_version" = 8.4
mariadb_version=$(dpkg-query -W -f='${Version}' mariadb-server)
apache_version=$(dpkg-query -W -f='${Version}' apache2)

grep -Fxq 'version=5.9' /usr/share/orangehrm/release
grep -Fxq 'sha256=f6e640f8b59e8d09f15edcd24ac3d42bb52dcc4839a7d83f964dd798bc793f79' \
    /usr/share/orangehrm/release
test -x /usr/local/sbin/orangehrm-update
update_candidate=$(orangehrm-update --check)
[[ $update_candidate =~ ^version=[0-9]+\.[0-9]+(\.[0-9]+)?\ sha256=[0-9a-f]{64}$ ]]

curl --insecure --fail --silent --show-error --location "$login" \
    -c "$cookie" >"$page"
grep -q 'OrangeHRM OS 5.9' "$page"
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
mysql --user=root --password="$db_password" --batch --skip-column-names \
    --execute="SELECT user_password FROM orangehrm.ohrm_user WHERE user_name='admin'" |
    grep -q '^\$2y\$'
mysql --user=root --password="$db_password" --batch --skip-column-names \
    --execute="SELECT value FROM orangehrm.hs_hr_config WHERE name='auth.password_policy.enforce_password_strength'" |
    grep -qx 'off'

curl --insecure --fail --silent --show-error -b "$cookie" \
    -H 'Content-Type: application/json' \
    --data '{"firstName":"TurnKey","middleName":"","lastName":"Acceptance","employeeId":"TKLV19"}' \
    "$base/web/index.php/api/v2/pim/employees" >"$json"
employee=$(jq -er '.data.empNumber' "$json")
curl --insecure --fail --silent --show-error -b "$cookie" \
    "$base/web/index.php/api/v2/pim/employees/$employee" >"$json"
jq -e '.data.firstName == "TurnKey" and .data.lastName == "Acceptance" and .data.employeeId == "TKLV19"' \
    "$json" >/dev/null
curl --insecure --fail --silent --show-error -b "$cookie" \
    -H 'Content-Type: application/json' -X DELETE \
    --data "{\"ids\":[$employee]}" \
    "$base/web/index.php/api/v2/pim/employees" >"$json"
jq -e --argjson employee "$employee" '.data | index($employee)' "$json" >/dev/null
employee=

if curl --insecure --fail --silent --show-error \
    "$base/installer/" >/dev/null 2>&1; then
    echo 'OrangeHRM installer remained web-accessible' >&2
    exit 1
fi

curl --insecure --fail --silent --show-error "$base:12322/" >"$page"
grep -qi 'Adminer' "$page"
curl --insecure --silent --show-error --location \
    --cookie-jar "$adminer_cookie" --cookie "$adminer_cookie" \
    --data-urlencode 'auth[driver]=server' \
    --data-urlencode 'auth[server]=localhost' \
    --data-urlencode 'auth[username]=adminer' \
    --data-urlencode "auth[password]=$db_password" \
    --data-urlencode 'auth[db]=orangehrm' \
    "$base:12322/" >"$page"
grep -qi 'MariaDB\|MySQL' "$page"
grep -qi 'Logout' "$page"
! grep -qi 'Invalid credentials\|Access denied' "$page"

dpkg-query -W webmin-apache webmin-mysql webmin-phpini >/dev/null
curl --insecure --fail --silent --show-error --head "$base:12321/" >/dev/null
ss -ltn | grep -Eq '127\.0\.0\.1:25[[:space:]]'

before="$apache_version|$mariadb_version|$(dpkg-query -W -f='${Version}' php)"
apt-get update >/dev/null
for package in apache2 mariadb-server php php-curl php-gd php-ldap php-mbstring php-mysql php-xml php-zip; do
    apt-cache policy "$package" >"$policy"
    candidate=$(awk '/Candidate:/ {print $2}' "$policy")
    test -n "$candidate"
    test "$candidate" != '(none)'
    grep -Eq 'trixie|deb13' "$policy"
done
after="$(dpkg-query -W -f='${Version}' apache2)|$(dpkg-query -W -f='${Version}' mariadb-server)|$(dpkg-query -W -f='${Version}' php)"
test "$after" = "$before"
grep -Rqs '^Suites: trixie' /etc/apt/sources.list.d
! grep -Rqi bookworm /etc/apt/sources.list.d

cat >"$result" <<EOF
package_source=Debian 13 Trixie APT repositories for Apache, PHP, MariaDB, Adminer and Postfix; verified official OrangeHRM GitHub release asset
installed_version=orangehrm $orangehrm_version; php $php_version; apache2 $apache_version; mariadb-server $mariadb_version
runtime_checks=normal init; Apache and MariaDB supervision; OrangeHRM HTTPS login with firstboot password; dashboard session; employee create, read and delete through the authenticated API with MariaDB persistence; blocked web installer; Adminer credential login; Webmin HTTPS; local Postfix listener
updater_command=orangehrm-update --check; orangehrm-update VERSION for a supervised backup, verified release migration and application swap; apt-get update and apt-cache policy for Debian packages
updater_result=official stable release metadata returned $update_candidate; signed Debian metadata refreshed with installed packages unchanged
updater_channel=official stable OrangeHRM GitHub releases with GitHub-published SHA-256 asset digests; Debian and TurnKey Trixie APT repositories
integrity_evidence=installed release marker records the pinned GitHub URL and SHA-256; updater requires the official release asset digest; APT accepted signed repository metadata; no Bookworm source remained
EOF
