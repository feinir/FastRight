.PHONY: build release app-store
build:
	./build.sh
	# Craft Anything looks for packaged apps in Build/.
	@test -d Build || ln -s dist Build

release:
	./release.sh

app-store:
	./build-app-store.sh package
