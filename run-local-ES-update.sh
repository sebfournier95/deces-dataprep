#!/bin/bash

sudo apt-get update -y && sudo apt-get install make

make clean
make config

# Copier le backup dans backend
cp -r ../backup/upload ./backend/upload

make datagouv-to-upload

make recipe-run
make watch-run

#make backup
