.PHONY: build release
build:
	./build.sh
	# Craft Anything looks for packaged apps in Build/.
	@test -d Build || ln -s dist Build

release:
	./release.sh
