#!/bin/bash
#===============================================================================
# Script: run-local-ES-update.sh
# Description: Mise à jour locale d'Elasticsearch avec les données de décès.
#
# Étapes principales:
#   1. Préparation de l'environnement (dépendances, configuration).
#   2. Traitement des données (datagouv -> upload -> recipe).
#   3. Notification Discord avec les statistiques d'indexation.
#   4. Création et archivage des backups locaux.
#
# Prérequis:
#   - Commande 'make' disponible.
#   - Fichier '../backup/upload' doit exister.
#   - DISCORD_WEBHOOK_URL défini dans le fichier 'artifacts' (optionnel).
#===============================================================================

#===============================================================================
# CONFIGURATION ET INITIALISATION
#===============================================================================

# Arrêter le script en cas d'erreur
set -e
trap 'echo "❌ Erreur détectée à la ligne $LINENO"' ERR

# Variables de chemins pour une meilleure lisibilité
UPLOAD_SOURCE_DIR="../backup/upload"
BACKEND_UPLOAD_DIR="./backend/upload"
BACKEND_BACKUP_DIR="./backend/backup"
BACKUP_DEST_DIR="../backup/"

#===============================================================================
# FONCTIONS
#===============================================================================
# Fonction pour préparer les données Elasticsearch
prepare_elasticsearch_data() {
    print_header "PRÉPARATION DES DONNÉES ELASTICSEARCH"

    # Créer le répertoire de backup local s'il n'existe pas
    echo "📁 Création du répertoire de backup local..."
    make backup-dir

    # Trouver la dernière archive de backup
    echo "📦 Recherche de la dernière archive de backup..."
    LATEST_BACKUP=$(ls -t ../backup/backup/esdata_*.tar 2>/dev/null | head -1)

    if [ -z "$LATEST_BACKUP" ]; then
        echo "❌ Erreur : Aucune archive esdata_*.tar trouvée dans ../backup/backup/"
        exit 1
    fi
    
    echo "    -> Archive trouvée : $(basename "$LATEST_BACKUP")"

    # Copier la dernière archive dans le dossier de backup local
    echo "    -> Copie de l'archive vers ./backend/backup/..."
    cp "$LATEST_BACKUP" ./backend/backup/

    # Définir le nom de l'archive
    ARCHIVE_NAME=$(basename "$LATEST_BACKUP")

    # Créer le répertoire de destination final pour les données extraites
    echo "    -> Création du répertoire de destination : backend/esdata/"
    mkdir -p ./backend/esdata

    # Extraire l'archive dans le répertoire de destination final
    echo "    -> Extraction de '$ARCHIVE_NAME' dans backend/esdata/..."
    tar -xf "./backend/backup/$ARCHIVE_NAME" -C ./backend
    
    echo "✅ Préparation des données Elasticsearch terminée avec succès."
}


# Fonction pour afficher les en-têtes de section
print_header() {
    echo ""
    echo "==============================================================================="
    echo " $1"
    echo "==============================================================================="
}

# Fonction pour charger les variables d'environnement depuis le fichier 'artifacts'
load_environment_variables() {
    print_header "ÉTAPE 1/5 : Chargement des variables d'environnement"
    if [ -f "artifacts" ]; then
        # Convertir les exports Make en exports Bash
        source <(grep "^export" artifacts | sed 's/export /export /')
        echo "✅ Variables d'environnement chargées depuis 'artifacts'."
    else
        echo "⚠️  Fichier 'artifacts' introuvable. Certaines fonctionnalités pourraient ne pas être disponibles."
    fi
}

# Fonction pour configurer les notifications Discord
setup_discord_notifications() {
    print_header "ÉTAPE 2/5 : Configuration des notifications Discord"
    if [ -z "$DISCORD_WEBHOOK_URL" ]; then
        echo "⚠️  DISCORD_WEBHOOK_URL n'est pas définie. Les notifications Discord seront ignorées."
        DISCORD_ENABLED=false
    else
        echo "✅ Notifications Discord activées."
        DISCORD_ENABLED=true
    fi
}

# Fonction pour envoyer une notification Discord
send_discord_notification() {
    if [ "$DISCORD_ENABLED" = true ]; then
        # Le -s silent mode évite d'afficher la sortie de curl
        curl -s -H "Content-Type: application/json" \
             -X POST \
             -d "{\"content\": \"$1\"}" \
             "$DISCORD_WEBHOOK_URL" > /dev/null
    fi
}

# Fonction pour exécuter le traitement des données
run_data_processing() {
    print_header "ÉTAPE 3/5 : Traitement des données"

    echo "📦 Copie du backup initial vers le backend..."
    if [ ! -d "$UPLOAD_SOURCE_DIR" ]; then
        echo "❌ Erreur : Le répertoire source '$UPLOAD_SOURCE_DIR' n'existe pas."
        exit 1
    fi
    # Assurer que le répertoire de destination parent existe
    mkdir -p "$(dirname "$BACKEND_UPLOAD_DIR")"
    
    echo "    -> Synchronisation de '$UPLOAD_SOURCE_DIR' vers '$BACKEND_UPLOAD_DIR'..."
    cp -r "$UPLOAD_SOURCE_DIR" "$BACKEND_UPLOAD_DIR"
    echo "    -> Suppression des fichiers temporaires et inutiles..."
    find "$BACKEND_UPLOAD_DIR" -type f \( -name "fichier-*" -o -name "tmp*" \) -delete
    echo "    -> Copie terminée."

    echo "🚚 Transfert des données de datagouv vers l'upload..."
    make datagouv-to-upload
    existe 0
    echo "🍳 Exécution de la recette de préparation des données..."
    make recipe-run
    make watch-run
    make down
    echo "✅ Traitement des données terminé."
}

# Fonction pour envoyer les statistiques d'indexation
send_indexation_stats() {
    print_header "ÉTAPE 4/5 : Envoi des statistiques d'indexation"
    local LOG_FILE
    LOG_FILE=$(find backend/log/ -iname '*deces_dataprep*' | sort | tail -1)

    if [ -f "$LOG_FILE" ]; then
        local STATS LINES_PROCESSED LINES_WRITTEN START_TIME END_TIME ES_DOC_COUNT
        STATS=$(grep "successfully fininshed" "$LOG_FILE" | tail -1)
        # Utilisation d'une regex plus fiable pour capturer tous les chiffres
        LINES_PROCESSED=$(echo "$STATS" | sed -n 's/.*, \([0-9]*\) lines processed.*/\1/p')
        LINES_WRITTEN=$(echo "$STATS" | sed -n 's/.*, \([0-9]*\) lines written.*/\1/p')
        
        START_TIME=$(head -1 "$LOG_FILE" | awk '{print $1" "$2}')
        END_TIME=$(grep "end of all" "$LOG_FILE" | awk '{print $1" "$2}')

        # Récupérer le nombre de documents depuis Elasticsearch (colonne 7)
        cd backend && make elasticsearch
        ES_DOC_COUNT=$(docker exec matchid-elasticsearch curl -s localhost:9200/_cat/indices | grep "deces" | awk '{print $7}')
        make elasticsearch-stop
        cd ..

        local message="✅ **Indexation des décès terminée !**\n\n📊 **Statistiques :**\n• Lignes traitées : **${LINES_PROCESSED}**\n• Lignes écrites : **${LINES_WRITTEN}**\n• Documents dans l'index : **${ES_DOC_COUNT}**\n• Début : ${START_TIME}\n• Fin : ${END_TIME}"
        send_discord_notification "$message"
        echo "📊 Statistiques d'indexation envoyées."
    else
        send_discord_notification "❌ **Erreur : fichier de log introuvable**"
        echo "❌ Fichier de log introuvable. Impossible d'envoyer les statistiques."
    fi
}

# Fonction pour créer les backups
create_backups() {
    print_header "ÉTAPE 5/5 : Création des backups locaux"
    
    echo "📁 Création du répertoire de backup..."
    make backup-dir
    make backup
    
    echo "🔄 Synchronisation des backups..."
    
    # Copie de l'upload mis à jour
    echo "    -> Nettoyage de l'ancien répertoire upload..."
    rm -rf "${BACKUP_DEST_DIR}/upload"
    echo "    -> Copie de l'upload mis à jour..."
    cp -r "$BACKEND_UPLOAD_DIR" "$BACKUP_DEST_DIR"

    cp -r "$BACKEND_UPLOAD_DIR" "$BACKUP_DEST_DIR"
    
    # Créer le répertoire backup de destination s'il n'existe pas
    mkdir -p "${BACKUP_DEST_DIR}/backup"
    
    # Trouver le dernier backup créé dans backend/backup
    echo "    -> Recherche du dernier backup..."
    LATEST_BACKUP=$(ls -t "${BACKEND_BACKUP_DIR}"/esdata_*.tar 2>/dev/null | head -1)
    
    if [ -n "$LATEST_BACKUP" ]; then
        echo "    -> Copie du backup: $(basename "$LATEST_BACKUP")"
        cp "$LATEST_BACKUP" "${BACKUP_DEST_DIR}/backup/"
        
        # Copier aussi le fichier .snar s'il existe
        SNAR_FILE="${LATEST_BACKUP%.tar}.snar"
        if [ -f "$SNAR_FILE" ]; then
            echo "    -> Copie du fichier snar: $(basename "$SNAR_FILE")"
            cp "$SNAR_FILE" "${BACKUP_DEST_DIR}/backup/"
        fi
        
        # Garder uniquement les 2 backups les plus récents (.tar)
        echo "    -> Nettoyage des anciens backups (conservation des 2 plus récents)..."
        cd "${BACKUP_DEST_DIR}/backup"
        ls -t esdata_*.tar 2>/dev/null | tail -n +3 | xargs -r rm -f
        
        # Supprimer aussi les fichiers .snar orphelins (sans .tar correspondant)
        shopt -s nullglob
        for snar in esdata_*.snar; do
            if [ -f "$snar" ] && [ ! -f "${snar%.snar}.tar" ]; then
                echo "    -> Suppression du fichier snar orphelin: $snar"
                rm -f "$snar"
            fi
        done
        shopt -u nullglob
        cd - > /dev/null
        
        # Afficher les backups conservés
        echo "    -> Backups conservés:"
        ls -lh "${BACKUP_DEST_DIR}/backup"/esdata_*.tar 2>/dev/null | awk '{print "       - " $9 " (" $5 ")"}'
        
        local BACKUP_COUNT=$(ls -1 "${BACKUP_DEST_DIR}/backup"/esdata_*.tar 2>/dev/null | wc -l)
        local message="💾 **Backups locaux à jour !**\n\n✅ Dernier backup copié avec succès\n📦 Nombre de backups conservés : **${BACKUP_COUNT}**/2\n📂 Répertoire : \`${BACKUP_DEST_DIR}backup\`"
        send_discord_notification "$message"
        echo "✅ Backups créés avec succès."
    else
        echo "⚠️  Aucun backup trouvé dans ${BACKEND_BACKUP_DIR}"
        send_discord_notification "⚠️ **Attention** : Aucun backup trouvé à copier"
    fi
}



#===============================================================================
# SCRIPT PRINCIPAL
#===============================================================================

main() {
    print_header "Démarrage du script de mise à jour locale d'Elasticsearch"

    echo "🔧 Vérification et installation des dépendances (make)..."
    sudo apt-get update -y && sudo apt-get install make -y

    echo "⚙️  Configuration du projet..."
    make clean
    make config

    load_environment_variables
    setup_discord_notifications
    run_data_processing
    send_indexation_stats
    create_backups

    print_header "🎉 Script terminé avec succès."
}

# Exécuter la fonction principale
main
