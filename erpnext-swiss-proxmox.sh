#!/usr/bin/env bash

set -e

# --- Helper functions ---
msg_info() { echo -e "\e[1;34m[INFO]\e[0m $1"; }
msg_ok()   { echo -e "\e[1;32m[OK]\e[0m $1"; }
msg_warn() { echo -e "\e[1;33m[WARN]\e[0m $1"; }
msg_err()  { echo -e "\e[1;31m[ERR]\e[0m $1"; }

ERP_USER="erpnext"
ERP_HOME="/home/$ERP_USER"
SITE_NAME="site1.local"
ADMIN_PASS="$(openssl rand -base64 18 | cut -c1-13)"
MYSQL_PASS="$(openssl rand -base64 18 | cut -c1-13)"
ERP_BRANCH="version-15"
FRAPPE_BRANCH="version-15"
SWISS_APP_URL="https://github.com/libracore/erpnextswiss"

msg_info "Updating OS and installing dependencies"
apt-get update && apt-get upgrade -y
apt-get install -y python3-minimal python3-pip python3-venv python3-setuptools \
  git curl sudo software-properties-common \
  mariadb-server mariadb-client redis-server \
  xvfb libfontconfig wkhtmltopdf \
  supervisor nginx build-essential libffi-dev python3-dev libssl-dev

msg_ok "System dependencies installed"

msg_info "Securing MariaDB"
service mysql start
mysql -u root <<MYSQL_SCRIPT
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_PASS}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

cat <<EOF >> /etc/mysql/mariadb.conf.d/50-server.cnf
[mysqld]
innodb-file-format=barracuda
innodb-file-per-table=1
innodb-large-prefix=1
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
EOF

systemctl restart mariadb
msg_ok "MariaDB secured and configured"

msg_info "Installing Node.js 18 LTS and Yarn"
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt-get install -y nodejs
npm install -g yarn
msg_ok "Node.js and Yarn installed"

if ! id "$ERP_USER" &>/dev/null; then
  msg_info "Creating erpnext user"
  useradd -m -s /bin/bash $ERP_USER
  echo "$ERP_USER ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
  chown -R $ERP_USER:$ERP_USER $ERP_HOME
  msg_ok "User $ERP_USER created"
else
  msg_warn "User $ERP_USER already exists, skipping"
fi

msg_info "Setting hostname"
hostnamectl set-hostname erpnext.lxc
echo "127.0.0.1 erpnext.lxc" >> /etc/hosts

msg_info "Installing Frappe Bench and ERPNext"
su - $ERP_USER -c "
  pip3 install --user frappe-bench
  export PATH=\$PATH:\$HOME/.local/bin
  bench init --frappe-branch $FRAPPE_BRANCH frappe-bench --python python3
  cd frappe-bench
  bench get-app --branch $ERP_BRANCH erpnext
  bench new-site $SITE_NAME --mariadb-root-password $MYSQL_PASS --admin-password $ADMIN_PASS --no-multitenancy
  bench --site $SITE_NAME install-app erpnext
"
msg_ok "ERPNext core installed"

msg_info "Installing ERPNext Swiss (localization)"
su - $ERP_USER -c "
  export PATH=\$PATH:\$HOME/.local/bin
  cd frappe-bench
  bench get-app erpnextswiss $SWISS_APP_URL
  bench --site $SITE_NAME install-app erpnextswiss
  bench restart
"
msg_ok "ERPNext Swiss installed"

msg_info "Setting up ERPNext for production"
su - $ERP_USER -c "
  export PATH=\$PATH:\$HOME/.local/bin
  cd frappe-bench
  bench setup production $ERP_USER
"
msg_ok "Production mode setup done"

cat <<CREDENTIALS > $ERP_HOME/erpnext.credentials.txt

===== ERPNext / ERPNext Swiss LXC Install =====

- ERPNext site:      http://<LXC-IP>
- Site name:         $SITE_NAME

- ERPNext Admin user:    Administrator
- ERPNext Admin pass:    $ADMIN_PASS

- MariaDB root pass:     $MYSQL_PASS

- Swiss App installed:   Yes
  (Go to 'Swiss Settings' in the ERPNext backend to configure)

==== File location: $ERP_HOME/erpnext.credentials.txt ====

CREDENTIALS

chown $ERP_USER:$ERP_USER $ERP_HOME/erpnext.credentials.txt

msg_ok "Credentials stored at $ERP_HOME/erpnext.credentials.txt"

msg_info "Cleaning up"
apt-get autoremove -y && apt-get autoclean -y
msg_ok "Done! Access ERPNext at: http://<container-ip>"

cat $ERP_HOME/erpnext.credentials.txt
