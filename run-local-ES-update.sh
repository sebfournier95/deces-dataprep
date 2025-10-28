#!/bin/bash

sudo apt-get update -y && sudo apt-get install make

make clean
make config

# Copier le backup dans backend
cp -r ../backup/upload ./backend/upload

make datagouv-to-upload

make recipe-run
make watch-run

make backup-dir
make backup

cp -r ./backend/upload ../backup/

rm -rf ../backup/backup
cp -r ./backend/backup ../backup/