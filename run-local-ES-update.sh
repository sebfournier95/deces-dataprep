#!/bin/bash

sudo apt-get update -y && sudo apt-get install make

make config

make datagouv-to-upload

make recipe-run
make watch-run

make backup
