#!/usr/bin/env bash

sudo rpm --import http://packages.confluent.io/rpm/2.0/archive.key
sudo cp /vagrant/configfiles/confluent.repo /etc/yum.repos.d/

sudo yum -y install http://dl.fedoraproject.org/pub/epel/6/x86_64/epel-release-6-8.noarch.rpm
sudo yum -y install java-1.8.0-openjdk java-1.8.0-openjdk-devel graphite-web python-carbon python-pip python-yaml wget emacs


# TODO: each package is installed separately to avoid installing librdkafka, which has yum dependency issues
#       librdkafka should be installed from a tar.
sudo yum -y install confluent-kafka-2.10.5 confluent-camus confluent-kafka-connect-hdfs confluent-kafka-connect-jdbc confluent-kafka-rest confluent-schema-registry

sudo service iptables stop
sudo chkconfig iptables off

# patch a small bug that prevented us from getting logs:
sed "s/^\s*KAFKA_LOG4J_OPTS/export KAFKA_LOG4J_OPTS/" </usr/bin/kafka-server-start > temp_start_script
sudo cp temp_start_script /usr/bin/kafka-server-start

sudo zookeeper-server-start -daemon /etc/kafka/zookeeper.properties 
sudo JMX_PORT=9990 LOG_DIR=/var/log/kafka0 kafka-server-start -daemon /vagrant/configfiles/server0.properties
sudo JMX_PORT=9991 LOG_DIR=/var/log/kafka1 kafka-server-start -daemon /vagrant/configfiles/server1.properties
sudo JMX_PORT=9992 LOG_DIR=/var/log/kafka2 kafka-server-start -daemon /vagrant/configfiles/server2.properties
# the startup scripts here don't properly daemonize, so I need to do it here
sudo nohup schema-registry-start /etc/schema-registry/schema-registry.properties </dev/null &>/dev/null &
sudo nohup kafka-rest-start /etc/kafka-rest/kafka-rest.properties </dev/null &>/dev/null &

sudo /usr/lib/python2.6/site-packages/graphite/manage.py syncdb --noinput
echo "from django.contrib.auth.models import User; User.objects.create_superuser('admin', 'myemail@example.com', 'hunter2')" | sudo /usr/lib/python2.6/site-packages/graphite/manage.py shell
sudo service carbon-cache start
sudo chkconfig carbon-cache on

sudo pip install gunicorn
sudo mkdir /var/run/gunicorn-graphite
sudo mkdir /var/log/gunicorn-graphite
sudo nohup gunicorn_django --bind=0.0.0.0:8000 --log-file=/var/log/gunicorn-graphite/gunicorn.log --preload --pythonpath=/usr/lib/python2.6/site-packages/graphite --settings=settings --workers=3 --pid=/var/run/gunicorn-graphite/gunicorn-graphite.pid </dev/null &>/dev/null &

wget http://central.maven.org/maven2/org/jmxtrans/jmxtrans/251/jmxtrans-251.rpm
sudo yum -y install jmxtrans-251.rpm
yaml2jmxtrans /vagrant/configfiles/kafka.yaml
sudo cp kafka_prod.json /var/lib/jmxtrans/
sudo service jmxtrans start


# install MIT Kerboeros, set-up SSL and install expect
yum install -y expect krb5-server krb5-libs krb5-workstation

PASSWORD=confluent
VALIDITY=365
DN="CN=test,OU=sslTesting,O=Confluent,L=Raleigh,ST=NC,C=US"

expect <<- DONE
	#!/usr/bin/expect

	# It shouldn't take longer than 2 minutes to create the database and add a principal.
	set timeout 120

	#Create KDC user database
	spawn kdb5_util create -s

		expect "Enter KDC database master key:"
			send "$PASSWORD\r"
		expect "Re-enter KDC database master key to verify:"
			send  "$PASSWORD\r"

	# Wait until kdb5_util returns control to subshell
	expect "$ "

	# Add vagrant principal
	spawn /usr/sbin/kadmin.local -q "addprinc vagrant"

		expect "Enter password for principal "
			send "$PASSWORD\r"
		expect "Re-enter password for principal "
			send "$PASSWORD\r"

	expect "$ "

DONE

# Edit KRB5 kdc/admin server and domain->realm mapping
sed -i -e  s/kerberos.example.com/$(hostname -f)/g /etc/krb5.conf
sed -i -e  s/example.com/$(hostname -d)/g /etc/krb5.conf

# Start KDC 
service krb5kdc start

# Kadmin util only needed for remote mgmt
# service krb5kdc start

# SSL setup 

SSLHOME=ssl
CERTS=$SSLHOME/certs
KEYS=$SSLHOME/keys

ROLES=( server client )

mkdir -p $KEYS $CERTS

# Create CA
expect <<- DONE
        set timeout 120

        spawn openssl req -new -x509 -subj "$(echo /$DN | sed 's/,/\//g')" -keyout $KEYS/ca-key -out $CERTS/ca-cert -days $VALIDITY -passin pass:confluent
                expect "Enter PEM pass phrase:"
                        send "$PASSWORD\r"
                expect "Verifying - Enter PEM pass phrase:"
                        send "$PASSWORD\r"
                expect "$ "
DONE

echo "CA created"

for ROLE in ${ROLES[*]}; do
     # Import root CA into trust store
     keytool -keystore $CERTS/kafka.$ROLE.truststore.jks \
          -alias CATrust \
          -noprompt \
          -keypass $PASSWORD \
          -storepass $PASSWORD \
          -import -file $CERTS/ca-cert 

     # Import root CA into keystore
     keytool -keystore $KEYS/kafka.$ROLE.keystore.jks \
	  -alias CATrust \
	  -noprompt \
	  -keypass $PASSWORD \
  	  -storepass $PASSWORD \
	  -import -file $CERTS/ca-cert

     # Generate key pair for Kafka role
     keytool -genkeypair \
        -keystore $KEYS/kafka.$ROLE.keystore.jks \
        -alias kafka-$ROLE \
        -keypass $PASSWORD \
        -storepass $PASSWORD \
        -dname "$DN" \
        -ext SAN=DNS:$(hostname -f) \
        -validity $VALIDITY

    # Create CSR, cert-file, with role’s private key
     keytool -keystore $KEYS/kafka.$ROLE.keystore.jks \
          -alias kafka-$ROLE \
          -noprompt \
          -keypass $PASSWORD \
          -storepass $PASSWORD \
          -certreq -file $CERTS/$ROLE-cert-file

     # Generate signed certificate cert-signed from request cert-file
     openssl x509 -req \
	  -CA $CERTS/ca-cert \
	  -CAkey $KEYS/ca-key \
          -CAcreateserial \
          -passin pass:$PASSWORD \
          -in $CERTS/$ROLE-cert-file \
          -out $CERTS/$ROLE-cert-signed \
          -days $VALIDITY \

     # Import cert-signed into the key store
     keytool -keystore $KEYS/kafka.$ROLE.keystore.jks \
          -alias kafka-$ROLE \
          -noprompt \
          -keypass $PASSWORD \
          -storepass $PASSWORD \
          -import -file $CERTS/$ROLE-cert-signed

done
