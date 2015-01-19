#! /bin/bash -ex


promptValue() {
 read -p "$1"": " val
 echo $val
}


detectOldSettings() {

# get current db name
OLD_AWX_DB_NAME=$(grep -m1 NAME $DB_CONFIG | awk -F\' '{print $4}')

# get the current db password
OLD_AWX_DB_PW=$(grep PASSWORD $DB_CONFIG | awk -F'"""' '{print $2}' )

# get the current db user
OLD_AWX_DB_USER=$(grep USER $DB_CONFIG |  awk -F\' '{print $4}')

# get the current db host
OLD_DB_HOST=$(grep HOST $DB_CONFIG |  awk -F\' '{print $4}')

# get the current db port
OLD_DB_HOST_PORT=$(grep PORT $DB_CONFIG | cut -f2 -d':'| tr -d ' '|sed 's/,//g')

}

promptOldSettings() {

if [ -z "$OLD_DB_HOST" ]; then
OLD_DB_HOST=$(promptValue "Enter old DB host")
fi

if [ -z "$OLD_DB_HOST_PORT" ]; then
OLD_DB_HOST_PORT=$(promptValue "Enter old DB host port")
fi

if [ -z "$OLD_AWX_DB_NAME" ]; then
OLD_AWX_DB_NAME=$(promptValue "Enter old Tower DB name")
fi

if [ -z "$OLD_AWX_DB_USER" ]; then
OLD_AWX_DB_USER=$(promptValue "Enter old Tower DB user")
fi

if [ -z "$OLD_AWX_DB_PW" ]; then
    while true
        do
            read -s -p "Enter old AWX DB user password: " password
            echo
            read -s -p "Enter old AWX DB user password (again): " password2
            echo
            [ "$password" = "$password2" ] && break
            echo "Please try again"
        done
    OLD_AWX_DB_PW=$password
fi

}



promptNewSettings() {
 if [ -z "$NEW_DB_HOST" ]; then
   NEW_DB_HOST=$(promptValue "Enter new DB host")
 fi

 if [ -z "$NEW_DB_HOST_PORT" ]; then
   NEW_DB_HOST_PORT=$(promptValue "Enter new DB host port")
 fi

 if [ -z "$NEW_AWX_DB_NAME" ]; then
   NEW_AWX_DB_NAME=$(promptValue "Enter new Tower DB name")
 fi

 if [ -z "$NEW_AWX_DB_USER" ]; then
   NEW_AWX_DB_USER=$(promptValue "Enter new Tower DB user")
 fi


 if [ -z "$NEW_AWX_DB_PW" ]; then
    while true
    do
        read -s -p "Enter new AWX DB user password: " password
        echo
        read -s -p "Enter new AWX DB user password (again): " password2
        echo
        [ "$password" = "$password2" ] && break
        echo "Please try again"
    done
   NEW_AWX_DB_PW=$password
 fi


 if [ -z "$NEW_DB_ADMIN_USER" ]; then
   NEW_DB_ADMIN_USER=$(promptValue "Enter new DB admin user")
 fi

 if [ -z "$NEW_DB_ADMIN_PW" ]; then
    while true
    do
        read -s -p "Enter new DB admin user password: " password
        echo
        read -s -p "Enter new DB admin user password (again): " password2
        echo
        [ "$password" = "$password2" ] && break
        echo "Please try again"
    done
   NEW_DB_ADMIN_PW=$password
 fi

}

detectRequirements () {

echo "Checking writing permission for $DB_CONFIG"
if [ ! -w $DB_CONFIG ]; then
    echo "You must run the script with a user who has write permission to"
    echo $DB_CONFIG
    exit 1
else
    echo "Success"
fi

echo "Checking for Tower installation"
if [ ! -d /etc/tower ];then
    echo "No Tower installation found."
    exit 1
else
    echo "Success"
fi

}

#optinally load a settings file that contains new and old db parameters
if [ ! -z "$1" ] && [ -r "$1" ]; then
        source $1
fi



### Begin 

DB_CONFIG="/etc/tower/conf.d/postgres.py"

echo ""
detectRequirements
promptNewSettings


# make sure Tower 2.1 or greater

echo "create awx database on the remote side"
ansible localhost -m postgresql_db -a "name=$NEW_AWX_DB_NAME port=$NEW_DB_HOST_PORT login_user=$NEW_DB_ADMIN_USER login_password=$NEW_DB_ADMIN_PW login_host=$NEW_DB_HOST" --connection=local


#prompt to confirm these things, and allow for override

echo "I need the settings for the database currently being used by Tower"
echo "Shall I attempt to detect these myself?"

read -r -p "Are you sure? [y/N] " detect_settings
if [[ $detect_settings =~ ^([yY][eE][sS]|[yY])$ ]]
then
    detectOldSettings
else
    promptOldSettings
fi



#echo the db password is $password

# stop all services but DB
ansible localhost -m service -a "name=redis state=stopped" --connection=local -s
ansible localhost -m service -a "name=httpd state=stopped" --connection=local -s
ansible localhost -m service -a "name=supervisord state=stopped" --connection=local -s



# dump the current database, could alternately write to .pgpass of operating user
echo "Dumping the current database to /var/lib/awx/db-migrate.sql"
PGPASSWORD=$OLD_AWX_DB_PW pg_dump -h "$OLD_DB_HOST" -p $OLD_DB_HOST_PORT -U $OLD_AWX_DB_USER $OLD_AWX_DB_NAME  -f /tmp/db.sql --no-acl --no-owner 

if [ $? != 0 ]; then
    echo "There was a problem dumping the database."
    exit 1
fi

# stop DB
ansible localhost -m service -a "name=postgresql state=stopped" --connection=local -s


echo "creating the awx user on the remote side"
ansible localhost -m postgresql_user -a "name=$NEW_AWX_DB_USER password=$NEW_AWX_DB_PW login_user=$NEW_DB_ADMIN_USER login_password=$NEW_DB_ADMIN_PW login_host=$NEW_DB_HOST port=$NEW_DB_HOST_PORT db=$NEW_AWX_DB_NAME" --connection=local


echo "Now going to import the database to the new location"
PGPASSWORD=$NEW_DB_ADMIN_PW psql  -h $NEW_DB_HOST -p $NEW_DB_HOST_PORT -U $NEW_DB_ADMIN_USER $NEW_AWX_DB_NAME < /tmp/db.sql

if [ $? != 0 ]; then
    echo "There was a problem importing the database."
    exit 1
fi

# Modifying the owner of the tables to the awx user because RDS rds_superuser is not
# able to REASSIGN (not a real superuser)
sql=$(PGPASSWORD=$NEW_DB_ADMIN_PW psql -h $NEW_DB_HOST -p $NEW_DB_HOST_PORT -U $NEW_DB_ADMIN_USER -qAt -c "SELECT 'ALTER TABLE '|| schemaname || '.' || tablename ||' OWNER TO $NEW_AWX_DB_USER;' FROM pg_tables WHERE NOT schemaname IN ('pg_catalog', 'information_schema') ORDER BY schemaname, tablename;" $NEW_AWX_DB_NAME) 

echo "Fixing table ownership"
PGPASSWORD=$NEW_DB_ADMIN_PW psql -h $NEW_DB_HOST -p $NEW_DB_HOST_PORT -U $NEW_DB_ADMIN_USER  -c "$sql" awx

echo "backing up configuration file"
cp /etc/tower/conf.d/postgres.py /etc/tower/conf.d/postgres.py.pre-migrate.$(date +"%s")

echo "writing new configuration file"
cat << EOF > /etc/tower/conf.d/postgres.py

# Ansible Tower database settings.

DATABASES = {
   'default': {
       'ATOMIC_REQUESTS': True,
       'ENGINE': 'django.db.backends.postgresql_psycopg2',
       'NAME': '$NEW_AWX_DB_NAME',
       'USER': '$NEW_AWX_DB_USER',
       'PASSWORD': """$NEW_AWX_DB_PW""",
       'HOST': '$NEW_DB_HOST',
       'PORT': $NEW_DB_HOST_PORT,
   }
}

# Use SQLite for unit tests instead of PostgreSQL.
if len(sys.argv) >= 2 and sys.argv[1] == 'test':
    DATABASES = {
        'default': {
            'ATOMIC_REQUESTS': True,
            'ENGINE': 'django.db.backends.sqlite3',
            'NAME': '/var/lib/awx/awx.sqlite3',
            # Test database cannot be :memory: for celery/inventory tests.
            'TEST_NAME': '/var/lib/awx/awx_test.sqlite3',
        }
    }
EOF

echo "Starting Tower"
ansible localhost -m service -a "name=ansible-tower state=started" --connection=local -s





