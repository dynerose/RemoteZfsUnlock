echo -e "\n\033[0;32m >> Install Requirements\033[0m"
sudo apt-get -y update 2>&1 >/dev/null
sudo /usr/bin/apt-get -y install git


if [ ! -d "$HOME/ansible-telepito" ]; then
	echo -e  "\n\033[0;32m >> Clone ansible-telepito repository\033[0m"
	git clone https://rozsay@bitbucket.org/topsoftzrt/ansible.git "$HOME/ansible-telepito"
else
	echo -e "\n\033[0;32m >> htpc-ansible is already available\033[0m"
fi
cd "$HOME/ansible-telepito"
# echo -e "\n\033[0;32m >> Run Wizard\033[0m"
# python3 scripts/wizard.py <&1
echo -e "\n\033[0;32m >> Installing ...\033[0m"
