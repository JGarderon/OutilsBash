#!/bin/bash

# --- Code retour d'erreur --- 
#	0 : 		aucune erreur majeure 
#	1 : 		une étape a rencontré une erreur 
# 	2 : 		pas root 
# 	8 : 		configuration du poste 
# 		1 : 		problème sur la copie d'un fichier 
# 	16 : 		création des utilisateurs 
# 		1 : 		problème sur les utilisateurs 
# 		2 : 		problème sur les groupes 
# 		4 : 		problème sur les secrets  
# 	32 : 		installation paquets correct (+ = incorrect) 
# 		1 : 		problème de droit ou de rèseau (apt-update) 
# 		2 : 		paquet inconnu dans une opération 
# 		4 : 		paquet connu mais impossible à installer dans une opération 
# 	64  : 		netplan correct (+ = en erreur)
# 		1 : 		copie du plan impossible 
# 		2 : 		netplan en erreur 
# 		4 : 		redémarrage du réseau impossible 
# 	127 : 		erreur de contexte (contexte inconnu)
# 	128 : 		erreur de contexte (contexte maître avec trop de paramêtres) 
# 	255 : 		réservé 

declare -A CODESRETOUR=( ["reseau"]="64" ["installation"]="32" ["utilisateurs"]="16" ["configuration"]="8" ) 

FICHIER_paquets="./paquets.source" 
FICHIER_log="./installation.log" 

DEBUG=1

TCP_HOTE="monserveur.fr"
TCP_PORT="80"

FICHIER_utilisateurs="./utilisateurs.source"
FICHIER_groupes="./groupes.source"
FICHIER_secrets="./secrets.source"

FICHIER_sources="./source"

jeloggue() {
	echo "$OPERATION : $@" >> "$FICHIER_log" 
	[ "$DEBUG" = "1" ] && echo "$@" 
}

jestoppe() { 
	jeloggue "$1" 
	jesignale "/signalement" <<< `cat "$FICHIER_log"` 2> /dev/null 
	exit "$2"
} 

jesignale() { 
	read data ; echo -e "POST $1 HTTP/1.0\n$data" > /dev/tcp/${TCP_HOTE}/${TCP_PORT}
	exit "$?" 
} 

CONTEXTE_configuration_netplan() { 
	OPERATION="Usage de 'netplan'"
	jeloggue "installation automatique du plan" 
	[ -f ./netplan ] || echo "network:
    ethernets: 
        enp3s0:
            nameservers:
                addresses: [8.8.8.8, 8.8.4.4]
            dhcp4: true
            dhcp6: false
    version: 2" > ./netplan ; 
    cp ./netplan /etc/netplan/9999-nothus-installation-auto.yaml || jestoppe "copie du plan impossible" 1 
    netplan apply || jestoppe "netplan en erreur" 2 
    systemctl restart systemd-networkd || jestoppe "redémarrage des services du réseau impossible" 4 
	jeloggue "fin de l'application de la stratégique réseau" 
    return 0 
} 

CONTEXTE_installation_paquets() { 
	jeloggue "mise à jour des fichiers de dépôts" 
	apt update 1> /dev/null 2>&1 || stopper "erreur : pas réseau ou pb de droit !" "1" 
	jeloggue "début de l'installation des paquets" 
	while read ligne 
	do 
		OPERATION=`cut -d "	" -f1 <<< "$ligne"` 
		paquets=`cut -d "	" -f2- <<< "$ligne"` 
		for paquet in $paquets 
		do 
			jeloggue "installation du ou des paquets : '$paquet'" 
			apt-cache show "$paquet" 1> /dev/null 2>&1 
			[ $? != 0 ] && jestoppe "paquet '$paquet' inconnu dans les dépôts" 2 
			apt install -y "$paquet" 
			[ $? != 0 ] && jestoppe "paquet '$paquet' inconnu dans les dépôts" 4 
		done 
	done <<< `cat "$FICHIER_paquets"` 
	jeloggue "tentative de nettoyage..." 
	apt autoremove
	apt autoclean 
	jeloggue "fin de l'installation" 
	return 0 
} 

CONTEXTE_creation_utilisateurs_routine_creation() { 
	jeloggue "tentative d'écriture des $3" 
	if [ -f "$1" ]
	then 
		cp "$1" "$2" || ( jeloggue "impossible de créer les $3" ; return "$4" ) 
		jeloggue "$3 : créés" 
	else 
		jeloggue "$3 : rien à créer" 
	fi 
}

CONTEXTE_creation_utilisateurs() { 
	jeloggue "gestion des identitées - début" 
	CONTEXTE_creation_utilisateurs_routine_creation "$FICHIER_utilisateurs" "/etc/passwd" "utilisateurs" "1" ; 
	CONTEXTE_creation_utilisateurs_routine_creation "$FICHIER_groupe" "/etc/group" "groupes" "2" ; 
	CONTEXTE_creation_utilisateurs_routine_creation "$FICHIER_shadow" "/etc/shado" "secrets" "4" 
	jeloggue "gestion des identitées - fin" 
	return 0 
} 

CONTEXTE_configuration_poste() { 
	jeloggue "démarrage des copies de configuration - début"
	if [ -f "$FICHIER_sources" ] 
	then 
		while read ligne 
		do
			source=`cut -d "	" -f1 <<< "$ligne"` 
			destination=`cut -d "	" -f2 <<< "$ligne"` 
			cp "$source" "$destination" 
			chattr +i "$destination" 
			if [ -f "$destination" ] 
			then 
				jeloggue "copie inviolable '$source -> $destination' ok" 
			else
				jeloggue "copie inviolable '$source -> $destination' en erreur"
				return 1
			fi 
		done <<< `cat $FICHIER_sources` 
	else
		jeloggue "aucun fichier de configuration à copier" 
	fi 
	jeloggue "démarrage des copies de configuration - fin" 
	return 0 
} 

############################# --- Démarrage (Julien Garderon, juillet 2020) 

touch $FICHIER_paquets 
touch $FICHIER_log 

OPERATION="Amorçage" 

if [[ $EUID -ne 0 ]]
then 
   jestoppe "vous devez être 'root'" 2 
fi

case $# in
	0) 
		jeloggue "contexte en script maître : mode automatique" 
		$0 reseau ; [ "$?" != 64 ] && exit 1 
		$0 installation ; [ "$?" != 32 ] && exit 1 
		$0 utilisateurs ; [ "$?" != 16 ] && exit 1 
		$0 configuration ; [ "$?" != 8 ] && exit 1 
		jeloggue "fin du mode automatique" 
		;; 
	1) 
		case $1 in 
			"reseau") 
				OPERATION="Réseau" 
				CONTEXTE_configuration_netplan 
				exit $((CODESRETOUR["reseau"]+$?)) 
				;; 
			"installation") 
				OPERATION="installation des paquets" 
				CONTEXTE_installation_paquets 
				exit $((CODESRETOUR["installation"]+$?)) 
				;; 
			"utilisateurs") 
				OPERATION="création des utilisateurs" 
				CONTEXTE_creation_utilisateurs 
				exit $((CODESRETOUR["utilisateurs"]+$?)) 
				;; 
			"configuration") 
				OPERATION="configuration du poste" 
				CONTEXTE_configuration_poste 
				exit $((CODESRETOUR["configuration"]+$?)) 
				;; 
			*) 
				exit 127 
		esac 
		;; 
	*) 
		jestoppe "fin pour contexte inconnu : trop de paramêtres" 128 
		;; 
esac







