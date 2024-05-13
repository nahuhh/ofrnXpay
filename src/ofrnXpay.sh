#/bin/bash
## Prerequisites
# Variables
BTCHOME=~/btcpay/scripts
NBX=~/.nbxplorer/Main
BTCPAY=~/.btcpayserver/Main
SOURCE=~/.btcpayserver/source
XMRWALLET=~/.bitmonero/wallets
DISTRO=$(cat /etc/*-release | grep "^ID=" | grep -E -o "[a-z]\w+")
RELEASE=$(cat /etc/*-release | grep "^VERSION_ID=" | grep -E -o "[0-9]\w+")

# Colors

# Title Bar
title="Manual Deploy BTCPayServer (XMR only)"
COLUMNS=$(tput cols)
title_size=${#title}
# Note $ is not needed before numeric variables
span=$(((COLUMNS + title_size) / 2))
printf "%${COLUMNS}s" " " | tr " " "*"
printf "%${span}s\n" "$title"
printf "%${COLUMNS}s" " " | tr " " "*"

#TODO color echos

# Confirm install
read -p 'Install BTCpayserver? [y/N] ' install
confirm=$(
        case "$install" in
        y|Y) echo "LGTM";;
        *) printf "Aborted";;
        esac)
if [ $confirm = "Aborted" ]; then
echo "Aborted!"
exit 0
elif [ $confirm = "LGTM" ]; then
echo "BEGINNING INSTALL"; sleep 1
fi

# Create dirctories
mkdir -p $BTCHOME
mkdir -p $SOURCE
mkdir -p $BTCPAY
mkdir -p $NBX
mkdir -p $XMRWALLET

## Download & install dependencies
# dotnet 6.0 & Postgres
read -p "Installing apt packages. Press enter to continue"
sudo apt update
sudo apt install -y git wget curl build-essential tmux
echo 'Installing Postgres' && sleep 2
sudo apt install -y postgresql postgresql-contrib

#dotnet 6.0
wget https://packages.microsoft.com/config/$DISTRO/$RELEASE/packages-microsoft-prod.deb -O packages-microsoft-prod.deb
sudo dpkg -i packages-microsoft-prod.deb
rm packages-microsoft-prod.deb
sudo apt-get update
sudo apt-get install -y apt-transport-https
sudo apt-get update
# Install dotnet 6.0
sudo apt install -y dotnet-sdk-6.0

## CONFIG PROMPTS
# Monero Node RPC
read -p 'Enter your XMR node daemon url
[example: 127.0.0.1: ' xmrnode
read -p 'Enter the RPC port of your XMR node
[example: 18081]:' xmrport
read -p 'Use SSL/TLS/HTTPS? [Y/n] ' usessl
xmrssl=$(
        case $usessl in
        n|N) echo 'http://' ;;
        *) echo 'https://' ;;
        esac)
# Create Postgres role
echo 'Creating a new postgres db user for btcpay.' && sleep 1
read -p 'Give the Role/User a name
[example: monero]: ' pgusr
read -p 'Create a password for the role
[example: monero]: ' pgpasswd
echo "In the next step, you'll repeat the same password as above
[example: monero]" && sleep 1
sudo -i -u postgres createuser -S -R -P -d $pgusr
#  Create Postgres databases
echo "Creating Database for btcpayserver and nbxplorer" && sleep 1
sudo -i -u postgres createdb btcpayserver -O $pgusr
sudo -i -u postgres createdb nbxplorer -O $pgusr

## Builds etc
# Monero INSTALL
cd $SOURCE
echo 'Downloading Monero software' && sleep 2
case $(uname -m) in
        aarch64_be | aarch64 | armv8b) MONERO_CLI_URL=https://downloads.getmonero.org/cli/androidarm8 ;;
        x86_64 | amd64) MONERO_CLI_URL=https://downloads.getmonero.org/cli/linux64 ;;
        *) echo "Your device is not compatible (or this check is broken)"; exit 1 ;;
esac
wget -c -O monero.tar.bzip2 $MONERO_CLI_URL
tar jxvf monero.tar.bzip2
#rm monero.tar.bzip2
sudo mv monero-*/monero* /usr/local/bin/
rm -rf monero-*

cd $SOURCE
# NBXplorer INSTALL
if [ -d $SOURCE/NBXplorer ]; then
echo "Updating NBXplorer"
git pull
else
echo "Installing NBXplorer" && sleep 1
git clone https://github.com/dgarage/NBXplorer
fi
cd NBXplorer
./build.sh

## BTCPAY INSTALL
if [ -d $SOURCE/btcpayserver ]; then
echo "Updating btcpayserver"
git pull
else
echo "Installing btcpayserver" && sleep 2
git clone https://github.com/btcpayserver/btcpayserver.git
fi
cd $SOURCE/btcpayserver
# Modify build.sh to include usable crypto
sed -i s'/ Release/ Altcoins-Release/' build.sh
# Build btcpay
./build.sh

## CREATE CONFIG FILES
# btcpayserver config
cd $BTCPAY
cat <<EOF > settings.config
network=mainnet
port=23001
bind=0.0.0.0
chains=xmr
XMR_daemon_uri=$xmrssl$xmrnode:$xmrport
XMR_wallet_daemon_uri=http://127.0.0.1:18082
XMR_wallet_daemon_walletdir=$XMRWALLET
# Only use username and password if node's RPC is password protected
XMR_daemon_username=$xmrusr
XMR_daemon_password=$xmrpasswd
protocol=http
torservices=btcpayserver:\$ONION:80
socksendpoint=127.0.0.1:9050
reverseproxy=none
#rootpath=/xmrpay
debuglog=btcpay.log
postgres=User ID="$pgusr";Password="$pgpasswd";Host=localhost;Port=5432;MaxPoolSize=80;Database=nbxplorer;
EOF

# NBXplorer config
cd $NBX
cat <<EOF > settings.config
#btc.rpc.auth=user:passwd
port=24444
mainnet=1
chains=
trimevents=10000
postgres=User ID="$pgusr";Password="$pgpasswd";Host=localhost;Port=5432;MaxPoolSize=20;Database=nbxplorer;
EOF

## Startup scripts
cd $BTCHOME
cat <<EOF > xmr-up
#!/bin/bash
monero-wallet-rpc \
	--rpc-bind-ip=127.0.0.1 \
	--disable-rpc-login \
	--rpc-bind-port=18082 \
	--non-interactive \
	--trusted-daemon \
	--daemon-address=$xmrssl$xmrnode:$xmrport \
	--wallet-file=$XMRWALLET/wallet \
	--password-file=$XMRWALLET/password \
	--tx-notify="/usr/bin/curl -X GET http://127.0.0.1:23001/monerolikedaemoncallback/tx?cryptoCode=xmr&hash=%s"
EOF
cat <<EOF > nbx-up
#!/bin/bash
cd $SOURCE/NBXplorer; ./run.sh
EOF
cat <<EOF > btc-up
#!/bin/bash
cd $SOURCE/btcpayserver; ./run.sh
EOF
cat <<EOF > startbps
#!/bin/bash
cd $BTCHOME
tmux new-session -d './xmr-up'
tmux split-window -h './nbx-up'
tmux select-pane -t 1
tmux split-window -h './btc-up'
tmux attach-session -d
EOF
chmod +x $BTCHOME/*

# Download Wallet SW
cd $BTCHOME
read -p 'Do you have an existing wallet? [Y/n]' feather
case $feather in
	n|N) echo "Installing Feather Wallet Flatpak";;
	*) echo "Perfect";;
esac
if [ $feather != "Perfect" ]; then
sudo apt install flatpak && flatpak install --from https://featherwallet.org
gpg --show-keys --with-fingerprint /var/lib/flatpak/repo/feather.trustedkeys.gpg
echo 'The output above should contain a line that says:
"Key fingerprint = 8185 E158 A333 30C7 FD61 BC0D 1F76 E155 CEFB A71C"
Only the letters and digits matter, you may ignore any extra or missing spaces.'
fi
echo "Create a View-Only Wallet using 'Feather Wallet' (or a wallet of your choice).
After creating a wallet, export it with the name "wallet" (case sensitive) and upload to btcpayserver"
echo 'Add this flag to your Monero node: "--block-notify="/usr/bin/curl -X GET http://$YOURPAYSERVERIP:23001/monerolikedaemoncallback/block?cryptoCode=xmr&hash=%s"'

echo "to install tor, in a new terminal window run:
1. sudo su
2. cd $SOURCE/btcpayserver && ./BPS-HS-SETUP.sh"
echo "Restarting btcpayserver now..."
pkill startbps
sleep 2
./startbps
