all: wagner.c equihash.c main.c blake
	gcc -O3 -g -pedantic -Wall -march=native -ffast-math -o chash *.c blake/*.c -lpthread

profile: all
	sudo operf ./chash
	opannotate --source --assembly ./chash > profile.out

clean:
	sudo rm -rf chash profile.out oprofile_data
