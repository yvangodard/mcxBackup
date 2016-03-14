#!/bin/bash

# Variables initialisation
version="mcxBackup v0.1 - 2016, Yvan Godard [godardyvan@gmail.com]"
scriptDir=$(dirname "${0}")
scriptName=$(basename "${0}")
scriptNameWithoutExt=$(echo "${scriptName}" | cut -f1 -d '.')
ldapDnBase=""
ldapServer="ldap://127.0.0.1"
location="/var/mcxBackups"
dataName="MCXbackup-$(date +%d.%m.%y@%Hh%M)"
datatmp="${location%/}/temp"
branchesToProcess="groups%computer_lists%computer_groups%users"
listBranchesToProcess=$(mktemp /tmp/${scriptNameWithoutExt}_listBranchesToProcess.XXXXX)
log=/var/log/${scriptNameWithoutExt}.log
logTemp=$(mktemp /tmp/${scriptNameWithoutExt}_logtemp.XXXXX)
logActive=0
withLdapBind="no"
ldapAdminUid=""
ldapAdminPass=""
dailyNumberBackups=14
weeklyNumberBackups=1

function displayHelp () {
	echo -e "$version\n"
	echo -e "Cet outil permet d'effectuer un backup régulier des MCX d'un serveur Mac 10.6."
	echo -e "Cet outil est placé sous la licence gpl-3.0 (GNU General Public License v3.0)"
	echo -e "\nAvertissement:"
	echo -e "Cet outil est distribué dans support ou garantie, la responsabilité de l'auteur ne pourrait être engagée en cas de dommage causé à vos données."
	echo -e "\nUtilisation:"
	echo -e "./${scriptName} [-h] | -r <DN Racine LDAP>"
	echo -e "               [-s <URL Serveur LDAP>] [-b <branches à explorer>]"
	echo -e "               [-a <LDAP admin UID>] [-p <LDAP admin password>]"
	echo -e "               [-d <nombre de jours de backups quotidiens à garder>]"
	echo -e "               [-w <nombre de semaines de backups hebdomadaires à garder>]"
	echo -e "               [-j <log file>]"
	echo -e "\n  -h:                                   Affiche cette aide et quitte."
	echo -e "\nParamètres obligatoires :"
	echo -e "  -r <DN racineLdap> :                  DN de base de l'ensemble des entrées du LDAP (ex. : 'dc=server,dc=office,dc=com')."
	echo -e "\nParamètres optionnels :"
	echo -e "  -s <URL Serveur LDAP> :               URL du serveur LDAP (ex. : 'ldap://ldap.serveur.office.com',"
	echo -e "                                        par défaut : '${ldapUrl}')"
	echo -e "  -b <branches à explorer> :            Branches du LDAP à explorer, contenant des MCX à sauvegarder,"
	echo -e "                                        (par défaut '${branchesToProcess}')."
	echo -e "                                        Séparer les valeurs par le signe '%'"
	echo -e "  -a <LDAP admin UID> :                 UID de l'administrateur ou utilisateur LDAP si un Bind est nécessaire"
	echo -e "                                        pour consulter l'annuaire (ex. : 'diradmin')."
	echo -e "  -p <LDAP admin password> :            Mot de passe de l'utilisateur si un Bind est nécessaire pour consulter"
	echo -e "                                        l'annuaire (sera demandé si absent)."
	echo -e "  -d <nbr de backups quotidiens> :      Nombre de jours pendant lesquels les backups quotidiens seront conservés."                                      
	echo -e "  -w <nbr de semaines de backups> :     Nombre de semaines pendant lesquelles les backups hebdomadaires seront conservés."
	echo -e "  -j <fichier log> :                    Assure la journalisation dans un fichier de log à renseigner en paramètre."
	echo -e "                                        (ex. : '${log}')"
	echo -e "                                        ou utilisez 'default' (${log})"
}

function error () {
	echo -e "\n*** Erreur ${1} ***"
	echo -e ${2}
	alldone ${1}
}

function alldone () {
	# Journalisation si nécessaire et redirection de la sortie standard
	[ ${1} -eq 0 ] && echo "" && echo ">>> Processus terminé OK !"
	if [ ${logActive} -eq 1 ]; then
		exec 1>&6 6>&-
		cat ${logTemp} >> ${log}
		cat ${logTemp}
	fi
	# Suppression des fichiers et répertoires temporaires
	rm -R /tmp/${scriptNameWithoutExt}*
	[[ -e ${datatmp} ]] && rm -R ${datatmp}
	exit ${1}
}

# Fonction utilisée plus tard pour les résultats de requêtes LDAP encodées en base64
function base64decode () {
	echo ${1} | grep :: > /dev/null 2>&1
	if [ $? -eq 0 ] 
		then
		value=$(echo ${1} | grep :: | awk '{print $2}' | perl -MMIME::Base64 -ne 'printf "%s\n",decode_base64($_)' )
		base64attribute=$(echo ${1} | grep :: | awk '{print $1}' | awk 'sub( ".$", "" )' )
		echo "${base64attribute} ${value}"
	else
		echo ${1}
	fi
}

# Fonction suppression espaces/retours ligne
function deleteLineBreaks () {
	perl -n -e 'chomp ; print "\n" unless (substr($_,0,1) eq " " || !defined($lines)); $_ =~ s/^\s+// ; print $_ ; $lines++;' -i ${1}
}

# Fonction test nombre entier
function testInteger () {
	test ${1} -eq 0 2>/dev/null
	if [[ $? -eq 2 ]]; then
		echo 0
	else
		echo 1
	fi
}

# Vérification des options/paramètres du script 
optsCount=0
while getopts "hr:s:b:a:p:d:w:j:" OPTION
do
	case "$OPTION" in
		h)	displayHelp="yes"
						;;
		r)	ldapDnBase=${OPTARG}
			let optsCount=$optsCount+1
						;;
	    s) 	ldapServer=${OPTARG}
						;;
	    b)  branchesToProcess=${OPTARG}
						;;
		d) 	[[ $(testInteger ${OPTARG}) -ne 1 ]] && error 2 "Le paramètre '-d ${OPTARG}' n'est pas correct."
			dailyNumberBackups=${OPTARG}
						;;
	    w)  [[ $(testInteger ${OPTARG}) -ne 1 ]] && error 2 "Le paramètre '-w ${OPTARG}' n'est pas correct."
			weeklyNumberBackups=${OPTARG}
						;;
		a)	ldapAdminUid=${OPTARG}
			[[ ${ldapAdminUid} != "" ]] && withLdapBind="yes"
						;;
		p)	ldapAdminPass=${OPTARG}
                        ;;
        j)	[ $OPTARG != "default" ] && log=${OPTARG}
			logActive=1
                        ;;
	esac
done

[[ ${displayHelp} = "yes" ]] && displayHelp

[[ $(whoami) != "root" ]] && error 3 "Cet outil doit être utilisé par le compte root. Utilisez 'sudo' si besoin."

if [[ ${optsCount} != "1" ]]
	then
        displayHelp
        error 2 "Le paramètre obligatoire n'a pas été renseigné."
fi

if [[ ${withLdapBind} = "yes" ]] && [[ ${ldapAdminPass} = "" ]]
	then
	echo "Entrez le mot de passe LDAP pour uid=${ldapAdminUid},cn=users,${ldapDnBase} :" 
	read -s ldapAdminPass
fi

# Redirection de la sortie strandard vers le fichier de log
if [ ${logActive} -eq 1 ]; then
	echo -e "\n>>> Merci de patienter ..."
	if [[ ! -e ${log} ]]; then
		mkdir -p $(dirname ${log})
		touch ${log}
	fi
	if [[ ! -e ${log} ]]; then
		logActive=0
		echo "Impossible d'écrire dans le fichier de log '${log}'."
		echo "Nous continuons sans journalisation."
	else
		exec 6>&1
		exec >> ${logTemp}
	fi
fi

echo -e "\n****************************** `date` ******************************\n"
echo -e "$0 démarré..."

# Création / accès au répertoire de backup
[[ ! -e ${location} ]] && mkdir -p ${location}
cd ${location}
[ $? -ne 0 ] && echo "*** Problème pour accéder au dossier ${location} ***" && error 1 "Il est impossible de poursuivre la sauvegarde."
 
## En fonction du jour, changement du nombre de backup à garder et du répertoire de destination
echo ""
if [ "$( date +%w )" == "0" ]; then
        [ ! -d dimanche ] && mkdir -p dimanche
        dataDir=${location}/dimanche
         # Période en jours de conservation des backups hebdomadaires
        keepNumber=$((${weeklyNumberBackups}*7+1))
        echo "Backup hebdomadaire, les backups des ${weeklyNumberBackups} dernières semaines seront gardés."
else
        [ ! -d quotidien ] && mkdir -p quotidien
        dataDir=${location}/quotidien
        # Période en jours de conservation des backups quotidiens
        keepNumber=$(echo ${dailyNumberBackups})
        echo "Backup quotidien, les backups des ${keepNumber} derniers jours seront gardés."
fi

## Création d'un répertoire temporaire pour la sauvegarde avant de zipper l'ensemble des exports
mkdir -p ${datatmp%/}/${dataName%/}
[ $? -ne 0 ] && error 1 "*** Problème pour créer le dossier ${datatmp}/${dataName} ***"

# LDAP connection test...
echo -e "\nTest de bind LDAP sur ${ldapServer} :"
[[ ${withLdapBind} = "no" ]] && ldapCommandBegin="ldapsearch -LLL -H ${ldapServer} -x"
[[ ${withLdapBind} = "yes" ]] && ldapCommandBegin="ldapsearch -LLL -H ${ldapServer} -D uid=${ldapAdminUid},cn=users,${ldapDnBase} -w ${ldapAdminPass}"

${ldapCommandBegin} -b ${ldapDnBase} > /dev/null 2>&1
if [ $? -ne 0 ]; then
	error 1 "Erreur de connexion LDAP sur ${ldapServer} (${ldapDnBase}).\nMerci de vérifier vos paramètres."
else
	echo -e "-> OK"
fi

# Export des branches à traiter 
echo ${branchesToProcess} | perl -p -e 's/%/\n/g' | perl -p -e 's/ //g' | awk '!x[$0]++' >> ${listBranchesToProcess}

for branch in $(cat ${listBranchesToProcess})
do
	echo -e "\nRecherche sur la branche cn=${branch},${ldapDnBase} :"
	# LDAP connection test...
	echo "Test de bind LDAP sur ${ldapServer} / cn=${branch},${ldapDnBase} :"
	${ldapCommandBegin} -b cn=${branch},${ldapDnBase} > /dev/null 2>&1
	if [ $? -ne 0 ]; then 
		error 1 "Erreur de connexion LDAP sur ${ldapServer} (cn=${branch},${ldapDnBase}).\nMerci de vérifier vos paramètres."
	else
		echo -e "-> OK"
	fi

	## Création d'un répertoire temporaire pour la sauvegarde avant de zipper l'ensemble des exports
	mkdir -p ${datatmp%/}/${dataName%/}/${branch%/}
	[ $? -ne 0 ] && error 1 "*** Problème pour créer le dossier ${datatmp%/}/${dataName%/}/${branch%/} ***"
	cd ${datatmp%/}/${dataName%/}/${branch%/}

	# Lister toutes les entrées
	allEntries=$(mktemp /tmp/${scriptNameWithoutExt}_allEntries_${branch}.XXXXX)
	allEntriesFiltered=$(mktemp /tmp/${scriptNameWithoutExt}_allEntriesFiltered_${branch}.XXXXX)
	if [[ ${branch} == "users" ]]; then
		attribute="uid"
	else
		attribute="cn"
	fi
	ldapsearch -LLL -x -b cn=${branch},${ldapDnBase} -H ${ldapServer} ${attribute} >> ${allEntries}
	deleteLineBreaks ${allEntries}
	oldIfs=$IFS ; IFS=$'\n'
	for branchEntry in $(cat ${allEntries} | grep "^${attribute}: ")
	do
		base64decode ${branchEntry} | perl -p -e "s/${attribute}: //g" | grep -v ^${branch} >> ${allEntriesFiltered}
	done
	IFS=$oldIfs

	# Pour chaque entrée on exporte le contenu
	for entry in $(cat ${allEntriesFiltered})
	do
		${ldapCommandBegin} -b ${attribute}=${entry},cn=${branch},${ldapDnBase} > /dev/null 2>&1
		if [ $? -eq 0 ]; then 
			## Création d'un répertoire temporaire pour la sauvegarde avant de zipper l'ensemble des exports
			mkdir -p ${datatmp%/}/${dataName%/}/${branch%/}/${entry%/}
			[ $? -ne 0 ] && error 1 "*** Problème pour créer le dossier ${datatmp%/}/${dataName%/}/${branch%/}/${entry%/} ***"
			cd ${datatmp%/}/${dataName%/}/${branch%/}/${entry%/}

			allMcxAttributes=$(mktemp /tmp/${scriptNameWithoutExt}_allMcxAttributes.XXXXX)
			${ldapCommandBegin} -b ${attribute}=${entry},cn=${branch},${ldapDnBase} apple-mcxsettings >> ${allMcxAttributes}
			deleteLineBreaks ${allMcxAttributes}
			oldIfs=$IFS ; IFS=$'\n'
			for mcxSetting in $(cat ${allMcxAttributes} | grep '^apple-mcxsettings:' )
			do
				name=""
				mcxCurrentAttribute=$(mktemp /tmp/${scriptNameWithoutExt}_mcxCurrentAttribute.XXXXX)
				base64decode ${mcxSetting} | perl -p -e 's/apple-mcxsettings: //g' >> ${mcxCurrentAttribute}
				name=$(xmllint --xpath '/plist/dict/dict/key' ${mcxCurrentAttribute} | perl -p -e 's/<key>//g' | perl -p -e 's/<\/key>/\n/g')
				cp ${mcxCurrentAttribute} ${datatmp%/}/${dataName%/}/${branch%/}/${entry%/}/${name}.plist
				rm ${mcxCurrentAttribute}
			done
			IFS=$oldIfs
			rm ${allMcxAttributes}
		fi
	done
	rm ${allEntries}
	rm ${allEntriesFiltered}
done

# On supprime les dossiers vides
find ${datatmp%/}/${dataName%/} -type d -empty -delete > /dev/null 2>&1

## On commpresse (TAR) tous et on créé un lien symbolique pour le dernier
cd ${datatmp%/}
echo ""
echo "Création de l'archive ${dataDir%/}/${dataName}.gz"
tar -czf ${dataDir}/${dataName}.gz ${dataName}
[ $? -ne 0 ] && error 1 "*** Problème lors de la création de l'archive ${dataDir%/}/${dataName}.gz ***"
cd ${dataDir}
chmod 600 ${dataName}.gz
[ -f last.gz ] && rm last.gz
ln -s ${dataDir%/}/${dataName}.gz ${dataDir%/}/last.gz
 
## On supprime le répertoire temporaire
[ -d ${datatmp%/}/${dataName} ] && rm -rf ${datatmp%/}/${dataName}
 
## On supprime les anciens backups
echo "Suppression des vieux backups éventuels"
find ${dataDir} -name "*.gz" -mtime +${keepNumber} -print -exec rm {} \;
[ $? -ne 0 ] && error 1 "Problème lors de la suppression des anciens backups"

alldone 0