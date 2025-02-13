#!/usr/bin/env bash
set -e

# set default value if not set
[ -z "$CMON_PASSWORD" ] && cmon_password='cmon' || cmon_password=$CMON_PASSWORD
[ -z "$MYSQL_ROOT_PASSWORD" ] && mysql_root_password='password' || mysql_root_password=$MYSQL_ROOT_PASSWORD
[ -z "$CMON_STOP_TIMEOUT" ] && cmon_stop_timeout=30 || cmon_stop_timeout=$CMON_STOP_TIMEOUT

# changes in 1.9.1 - start
if [ -z "$DOCKER_HOST_ADDRESS" ]; then
	echo '>> Unable to start because DOCKER_HOST_ADDRESS is empty.'
	echo '>> New in ClusterControl 1.9.1:'
	echo '   Kindly specify the DOCKER_HOST_ADDRESS environment variable.'
	echo '   This value should be the same as the Docker host primary IP address (or hostname/FQDN) where you will connect.'
	echo '   If the container is running on a bridge network, do publish port 9443 and 19501 as well.'
	echo '   This is mandatory for ClusterControl GUI v2 to operate correctly.'
	echo '   Example: '
	echo '       -e DOCKER_HOST_ADDRESS="192.168.10.10" \'
	echo '	     -p 9443:9443 \'
	echo '	     -p 19501:19501 \'
	exit 1
fi
# changes in 1.9.1 - end

CMON_CONFIG=/etc/cmon.d/cmon.cnf
SSH_KEY=/root/.ssh/id_rsa
MOUNT_SSH_KEY=/mnt/key/id_rsa
WWWROOT=/var/www/html
PUB_KEY_DIR=$WWWROOT/keys
CCUI_BOOTSTRAP=$WWWROOT/clustercontrol/bootstrap.php
CCUI_SQL=$WWWROOT/clustercontrol/sql/dc-schema.sql
BANNER_FILE='/root/README_IMPORTANT'
MYSQL_CMON_CNF=/etc/my_cmon.cnf
IP_ADDRESS=$(ip a | grep eth0 | grep inet | awk {'print $2'} | cut -d '/' -f 1 | head -1)
[ -z $IP_ADDRESS ] && IP_ADDRESS=$(hostname -i | awk {'print $1'} | tr -d ' ')
HOSTNAME=$(hostname)
DATADIR=/var/lib/mysql
PIDFILE=${DATADIR}/mysqld.pid
SOCKETFILE=${DATADIR}/mysql.sock
MYSQL_INITIALIZE=0
INSTALLATION_STATUS=0
LAST_MSG='Installation successful'
S9S_CLI=/usr/bin/s9s

ping_stats() {
	[[ $(command -v cmon) ]] && VERSION=$(cmon --version | awk '/version/ {print $3}')
	UUID=$(basename "$(head /proc/1/cgroup)" | sed "s/docker-\(.*\).scope/\\1/")
	OS=$(cat /proc/version)
	OS=$(python -c "import sys,urllib; print urllib.quote('${OS}')")
	MEM=$(free -m | awk '/Mem:/ { print "T:" $2, "F:" $4}')
	MEM=$(python -c "import sys,urllib; print urllib.quote('${MEM}')")
	LAST_MSG=$(python -c "import sys,urllib; print urllib.quote('${LAST_MSG}')")
	CONTAINER=docker
	timeout 5 wget -qO- --post-data="version=${VERSION:=NA}&uuid=${UUID}&os=${OS}&mem=${MEM}&rc=${INSTALLATION_STATUS}&msg=${LAST_MSG}&container=${CONTAINER}" https://severalnines.com/service/diag.php &>/dev/null || true
}


## Check whether initializing MySQL data directory is necessary.
## /var/lib/mysql on new volume is usually empty.

echo ">> Starting ClusterControl container [$(date)]"
echo ">> Controller version: $(cmon -v | grep -i version | awk {'print $3'})"

if [ "$(ls -A $DATADIR)" ]; then
	echo ">> Datadir is not empty.."
	echo ">> Checking for lost+found existance"
	## Check if lost+found directory exists alone

	if [ -e ${DATADIR}/lost+found ] && [ $(ls -A ${DATADIR} | wc -l) -eq 1 ]; then
		echo ">> Found 'lost+found' directory alone. Proceed to initialize MySQL anyway.."
		MYSQL_INITIALIZE=1
	else
		[ -f $PIDFILE ] && rm -f $PIDFILE
		[ -f $SOCKETFILE ] && rm -f $SOCKETFILE
	fi
else
	MYSQL_INITIALIZE=1
fi

if [ $MYSQL_INITIALIZE -eq 1 ]; then
	echo ">> Datadir is empty. Initializing datadir.."
	mysql_install_db --user=mysql --datadir="$DATADIR" --rpm
fi

echo ">> Ensure MySQL datadir has correct permission/ownership.."
chown -R mysql:mysql "$DATADIR"

echo
echo '>> Starting MySQL daemon..'
[ -f $PIDFILE ] && rm -f $PIDFILE
[ -f $SOCKETFILE ] && rm -f $SOCKETFILE

start_mysqld() {
	/usr/bin/mysqld_safe --plugin-dir=/usr/lib64/mysql/plugin --socket=${SOCKETFILE} &
}

stop_mysqld() {
	echo
	echo '>> Stopping MySQL daemon so Supervisord can take over'
	killall -15 mysqld_safe mysqld
	sleep 3
}

if [ -z $(pidof mysqld) ]; then
	start_mysqld
else
	killall -9 mysqld
	start_mysqld
fi
sleep 3

echo
if [ ! -z $(pidof mysqld) ]; then
	echo '>> MySQL started. Looking for existing cmon/dcps data..'
	echo
	if [ "$(ls -A $DATADIR/cmon 2>/dev/null)" ]; then
		echo '>> Found existing cmon/dcps database'
		echo '>> Setting INITIALIZED=1'
		INITIALIZED=1
	else
		echo '>> It looks like this is a new instance..'
		echo '>> Setting INITIALIZED=0'
		INITIALIZED=0
	fi
else
	echo '>> MySQL failed to start. Aborting..'
	INSTALLATION_STATUS=1
	LAST_MSG='MySQL failed to start. Aborting..'
	exit 1
fi

create_mysql_cmon_cnf() {
	## Create /etc/cmon.d/my_cmon.cnf
	if [ -f $CMON_CONFIG ]; then
		rm -f /etc/cmon.cnf
	elif [ -f /etc/cmon.cnf ]; then
		mv /etc/cmon.cnf $CMON_CONFIG
	fi
	cmon_pwd=$(grep mysql_password $CMON_CONFIG | sed 's|^mysql_password=||g')
	cat > "$MYSQL_CMON_CNF" << EOF
[mysql_cmon]
user=cmon
password=$cmon_pwd
EOF
}

generate_ssh_key() {
	## Generate SSH keys
	echo
	echo ">> Generating SSH key for root at $SSH_KEY.."
	AUTHORIZED_FILE=/root/.ssh/authorized_keys
	KNOWN_HOSTS=/root/.ssh/known_hosts
	if [ -f $MOUNT_SSH_KEY ]; then
		cp $MOUNT_SSH_KEY $SSH_KEY
		cp ${MOUNT_SSH_KEY}.pub ${SSH_KEY}.pub
	else
		ssh-keygen -t rsa -N "" -f $SSH_KEY
	fi
	cat ${SSH_KEY}.pub >> $AUTHORIZED_FILE
	[ -d $PUB_KEY_DIR ] || mkdir -p $PUB_KEY_DIR
	cat ${SSH_KEY}.pub > $PUB_KEY_DIR/cc.pub
	chown -Rf apache:apache  $PUB_KEY_DIR
	KEY_TYPE=$(awk {'print $1'} ${SSH_KEY}.pub)
	PUB_KEY=$(awk {'print $2'} ${SSH_KEY}.pub)
	echo "$IP_ADDRESS $KEY_TYPE $PUB_KEY" >> $KNOWN_HOSTS
	chmod 600 $AUTHORIZED_FILE
}

if [ $INITIALIZED -eq 1 ]; then

	## Bootstrap ClusterControl

	sleep 5
	[ ! -f $MYSQL_CMON_CNF ] && create_mysql_cmon_cnf
	cmon_token=$(mysql --defaults-file=$MYSQL_CMON_CNF --defaults-group-suffix=_cmon -A -Bse "SELECT token FROM dcps.apis" 2> /dev/null)
	echo

	if [ ! -z $cmon_token ]; then
		CMON_EXISTING_TOKEN=$cmon_token
		echo ">> Existing token: $CMON_EXISTING_TOKEN"

		echo
		echo '>> Updating API token..'
		sed -i "s|^rpc_key=.*|rpc_key=$CMON_EXISTING_TOKEN|g" $CMON_CONFIG
		sed -i "s|^define('RPC_TOKEN'.*|define('RPC_TOKEN', '$CMON_EXISTING_TOKEN');|g" $CCUI_BOOTSTRAP

		echo
		echo '>> Retrieving existing cmon credentials..'
		cmon_pass=$(grep mysql_password $CMON_CONFIG | sed 's|^mysql_password=||g')
		cmon_port=$(grep mysql_port $CMON_CONFIG | sed 's|^mysql_port=||g')

		[ -z $cmon_pass ] && CMON_EXISTING_PASS=$cmon_password || CMON_EXISTING_PASS=$cmon_pass
		[ -z $cmon_port ] && CMON_EXISTING_PORT=3306 || CMON_EXISTING_PORT=$cmon_port

		echo
		echo '>> Updating database credentials..'
		sed -i "s|^define('DB_PASS'.*|define('DB_PASS', '$(echo ${CMON_EXISTING_PASS} | sed -e 's/\\/\\\\/g; s/\//\\\//g; s/&/\\\&/g')');|g" $CCUI_BOOTSTRAP
		sed -i "s|^define('DB_PORT'.*|define('DB_PORT', '$CMON_EXISTING_PORT');|g" $CCUI_BOOTSTRAP

		echo
		echo '>> Setting up public key directory..'
		if [ -f $SSH_KEY ]; then
			[ -d $PUB_KEY_DIR ] || mkdir -p $PUB_KEY_DIR
			cat ${SSH_KEY}.pub > $PUB_KEY_DIR/cc.pub
			chown -Rf apache:apache  $PUB_KEY_DIR
		else
			generate_ssh_key
		fi

		echo
		echo '>> Updating existing dcps schema'
		mysql --defaults-file=$MYSQL_CMON_CNF --defaults-group-suffix=_cmon -f dcps < $CCUI_SQL

		echo
		echo '>> Bootstrapping completed.'
	else
		echo 'Unable to retrieve existing token.'
	fi
else
	## Start ClusterControl initialization

	[ ! -f $SSH_KEY ] && generate_ssh_key

	## Configure CMON service

	CMON_TOKEN=$(cat /proc/sys/kernel/random/uuid | sha1sum | cut -f1 -d' ')
	echo
	echo ">> Setting up minimal $CMON_CONFIG.."
	cat /dev/null > $CMON_CONFIG
	cat > "$CMON_CONFIG" << EOF
mysql_port=3306
mysql_hostname=localhost
mysql_password=$cmon_password
hostname=$HOSTNAME
rpc_key=$CMON_TOKEN
EOF
	## Configure ClusterControl UI

	echo
	echo '>> Setting up ClusterControl UI'
	sed -i "s|^define('DB_HOST'.*|define('DB_HOST', 'localhost');|g" $CCUI_BOOTSTRAP
	sed -i "s|^define('DB_PASS'.*|define('DB_PASS', '$(echo ${cmon_password} | sed -e 's/\\/\\\\/g; s/\//\\\//g; s/&/\\\&/g')');|g" $CCUI_BOOTSTRAP
	sed -i "s|DBPORT|3306|g" $CCUI_BOOTSTRAP
	sed -i "s|RPCTOKEN|$CMON_TOKEN|g" $CCUI_BOOTSTRAP

	mysql=( mysql -uroot -h127.0.0.1 )

	if echo 'SELECT 1' | "${mysql[@]}" &> /dev/null; then

		## Create schemas and import
		echo
		echo '>> Importing CMON data..'
		mysql -uroot -h127.0.0.1 -e 'create schema cmon; create schema dcps;' && \
			mysql -f -uroot -h127.0.0.1 cmon < /usr/share/cmon/cmon_db.sql && \
				mysql -f -uroot -h127.0.0.1 cmon < /usr/share/cmon/cmon_data.sql && \
					mysql -f -uroot -h127.0.0.1 dcps < $WWWROOT/clustercontrol/sql/dc-schema.sql

		## Configure CMON user & password
		echo
		echo '>> Configuring CMON user and MySQL root password..'
		TMPFILE=/tmp/configure_cmon.sql
		cat > "$TMPFILE" << EOF
UPDATE mysql.user SET Password=PASSWORD('$mysql_root_password') WHERE User='root';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test; DELETE FROM mysql.db WHERE DB='test' OR DB='test\\_%';
GRANT ALL PRIVILEGES ON *.* TO 'cmon'@'localhost' IDENTIFIED BY '$cmon_password' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'cmon'@'127.0.0.1' IDENTIFIED BY '$cmon_password' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'cmon'@'$IP_ADDRESS' IDENTIFIED BY '$cmon_password' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'cmon'@'$HOSTNAME' IDENTIFIED BY '$cmon_password' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'cmon'@'%' IDENTIFIED BY '$cmon_password' WITH GRANT OPTION;
REPLACE INTO dcps.apis(id, company_id, user_id, url, token) VALUES (1, 1, 1, 'https://127.0.0.1/cmonapi', '$CMON_TOKEN');
CREATE TABLE cmon.containers (id INT PRIMARY KEY AUTO_INCREMENT, did INT, hostname VARCHAR(255), ip VARCHAR(128), cluster_type VARCHAR(128), cluster_name VARCHAR(255), vendor VARCHAR(128), provider_version VARCHAR(16), db_root_password VARCHAR(255), initial_size INT, deploying TINYINT NOT NULL DEFAULT 0, deployed TINYINT NOT NULL DEFAULT 0, created TINYINT NOT NULL DEFAULT 0);
FLUSH PRIVILEGES;
EOF

		mysql -uroot -h127.0.0.1 < $TMPFILE; rm -f $TMPFILE

		echo
		echo '>> Configuring CMON MySQL defaults file..'
		cat > "$MYSQL_CMON_CNF" << EOF
[mysql_cmon]
user=cmon
password=$cmon_password
EOF

	fi

	[ -f $CMON_CONFIG ] && rm -f /etc/cmon.cnf

	echo "!! Please remember following information which generated during entrypoint !!" > $BANNER_FILE
	[ -z "$CMON_PASSWORD" ] && echo ">> Generated CMON password: $cmon_password" >> $BANNER_FILE || echo "CMON password: $cmon_password" >> $BANNER_FILE
	[ -z "$MYSQL_ROOT_PASSWORD" ] &&	echo "Generated MySQL root password: $mysql_root_password" >> $BANNER_FILE || echo "MySQL root password: $mysql_root_password" >> $BANNER_FILE
	echo "Generated ClusterControl API Token: $CMON_TOKEN" >> $BANNER_FILE
	echo "Detected IP address: $IP_ADDRESS" >> $BANNER_FILE
	echo "To access ClusterControl UI, go to http://${IP_ADDRESS}/clustercontrol" >> $BANNER_FILE
fi

if ! $(/usr/bin/grep -q dba /etc/passwd); then
	## Setting up ssh daemon

	echo
	echo '>> Preparing SSH daemon'
	[ -d /var/run/sshd ] ||  mkdir /var/run/sshd
	[ -f /etc/ssh/ssh_host_rsa_key ] || ssh-keygen -t rsa -f /etc/ssh/ssh_host_rsa_key -N ''
	[ -f /etc/ssh/ssh_host_dsa_key ] || ssh-keygen -t dsa -f /etc/ssh/ssh_host_dsa_key -N ''

	## Configure s9s CLI

	echo
	echo '>> Starting CMON to grant s9s CLI users..'
	[ -e /var/run/cmon.pid ] && rm -f /var/run/cmon.pid
	/usr/sbin/cmon --rpc-port=9500 --events-client=http://127.0.0.1:9510
	sleep 7
	cmon_user=dba

	echo '>> Generating key for s9s CLI'
	[ -d /var/lib/cmon ] || mkdir -p /var/lib/cmon
	$S9S_CLI user --create --generate-key --group=admins --controller="https://localhost:9501" $cmon_user || :
	S9S_CONF=/root/.s9s/s9s.conf
	if [ -f $S9S_CONF ]; then
		echo '>> Configuring s9s.conf'
		echo "cmon_user            = $cmon_user" >> $S9S_CONF
		echo 'controller_host_name = localhost' >> $S9S_CONF
		echo 'controller_port      = 9501' >> $S9S_CONF
		echo 'rpc_tls              = true' >> $S9S_CONF
	fi

	## Changes 1.8.2 - start ##
	## Configure ccrpc user

	export S9S_USER_CONFIG=/root/.s9s/ccrpc.conf
	[ ! -z $CMON_EXISTING_TOKEN ] && CMON_TOKEN=$CMON_EXISTING_TOKEN
	$S9S_CLI user --create --generate-key --new-password=${CMON_TOKEN} --group=admins --controller="https://localhost:9501" ccrpc || :
	unset S9S_USER_CONFIG

	echo
	echo '>> Testing ccrpc user..'
	if $S9S_CLI user --cmon-user=ccrpc --password=${CMON_TOKEN} --list &>/dev/null; then
		echo '>> Looks good.'
	else
		echo '>> Unable to connect to the cmon controller as ccrpc user.'
		echo '>> Please fix it later, once container has started.'
	fi

	## Handling /etc/cmon-ldap.cnf
	## Workaround: make sure cmon-ldap.cnf is located under /etc/cmon.d for persistent storage

#	DEFAULT_CMON_LDAP=/etc/cmon-ldap.cnf
#	DOCKER_CMON_LDAP=/etc/cmon.d/cmon-ldap.cnf

#	echo
#	echo '>> Checking /etc/cmon-ldap.cnf..'

#	if [ -f $DOCKER_CMON_LDAP ]; then
#		if [ -L $DEFAULT_CMON_LDAP ]; then
#			echo '>> /etc/cmon-ldap.cnf symlinked to /etc/cmon.d/cmon-ldap.cnf..'
#		else
#			rm -f $DEFAULT_CMON_LDAP
#			echo '>> Linking /etc/cmon-ldap.cnf with existing /etc/cmon.d/cmon-ldap.cnf..'
#			ln -sf $DOCKER_CMON_LDAP $DEFAULT_CMON_LDAP
#		fi
#	else
#		echo '>> Cant find existing /etc/cmon.d/cmon-ldap.cnf. Trying to symlink it if exists..'
#		[ -f $DEFAULT_CMON_LDAP ] && mv $DEFAULT_CMON_LDAP $DOCKER_CMON_LDAP && ln -sf $DOCKER_CMON_LDAP $DEFAULT_CMON_LDAP
#	fi

	## Changes 1.8.2 - end ##

	## CMON process clean up. Possible fix for #8168
	echo
	echo '>> Checking PID of cmon process..'
	echo ">> CMON_STOP_TIMEOUT=$cmon_stop_timeout"

	PIDCMON=$(pidof cmon)
	echo ">> PID of cmon(s): -- ${PIDCMON} --"

	if [ ! -z "$PIDCMON" ]; then
		kill -15 $PIDCMON
		for (( i=1; i<=${cmon_stop_timeout}; i++ )); do
			if pidof cmon; then
				echo '>> Stopping CMON with SIGTERM..'
				echo ">> Count: $i/${cmon_stop_timeout}"
				sleep 1
			else
				break
			fi
		done
		if pidof cmon &>/dev/null; then
			echo '>> Timeout reached. Stopping CMON with SIGKILL..'
			kill -9 $(pidof cmon)
			sleep 1
		fi
	 	pidof cmon &>/dev/null && echo '>> CMON is still running. SIGKILL failed.' || echo '>> CMON stopped'
		[ -e /var/run/cmon.pid ] && rm -f /var/run/cmon.pid
		mysql --defaults-file=$MYSQL_CMON_CNF --defaults-group-suffix=_cmon -A -f -Bse 'DELETE FROM cmon.cdt_folders WHERE full_path = "/.runtime/controller_pid"'
		mysql --defaults-file=$MYSQL_CMON_CNF --defaults-group-suffix=_cmon -A -f -Bse 'DELETE FROM cmon.cdt_folders WHERE full_path = "/.runtime/controller_clock"'
	fi

	if ! $(grep -q CONTAINER $CCUI_BOOTSTRAP); then
		echo "define('CONTAINER', 'docker');" >> $CCUI_BOOTSTRAP
	fi
	
	CCUI2_CONFIG=/var/www/html/clustercontrol2/config.js
	sed -i "s|^  CMON_API_URL.*|  CMON_API_URL: 'https:\/\/${DOCKER_HOST_ADDRESS}:8080\/v2',|g" $CCUI2_CONFIG
fi

# Clean up

stop_mysqld
[ -e /etc/s9s.conf ] && rm -Rf /etc/s9s.conf
[ -e /run/httpd/httpd.pid ] && rm -f /run/httpd/httpd.pid
echo '>> Sleeping 15s for the stopping processes to clean up..'
sleep 15
ping_stats

# Start everything

echo ""
echo ">> Starting Supervisord and all related services:"
echo ">> sshd, httpd, cmon, cmon-events, cmon-ssh, cc-auto-deployment"
/usr/bin/supervisord -c /etc/supervisord.conf
