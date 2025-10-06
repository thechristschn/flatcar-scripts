# Copyright 2014-2016 CoreOS, Inc.
# Distributed under the terms of the GNU General Public License v2

EAPI=7
COREOS_SOURCE_REVISION=""
inherit coreos-kernel savedconfig

DESCRIPTION="CoreOS Linux kernel modules"
KEYWORDS="amd64 arm64"
RDEPEND="!<sys-kernel/coreos-kernel-4.6.3-r1"

src_prepare() {
	default
	restore_config build/.config
	if [[ ! -f build/.config ]]; then
		local archconfig="$(find_archconfig)"
		local commonconfig="$(find_commonconfig)"
		elog "Building using config ${archconfig} and ${commonconfig}"
		cat "${archconfig}" "${commonconfig}" | envsubst '$MODULE_SIGNING_KEY_DIR' >> build/.config || die
	fi
	cpio -ov </dev/null >build/bootengine.cpio

	# Check that an old pre-ebuild-split config didn't leak in.
	grep -q "^CONFIG_INITRAMFS_SOURCE=" build/.config && \
		die "CONFIG_INITRAMFS_SOURCE must be removed from kernel config"
	config_update 'CONFIG_INITRAMFS_SOURCE="bootengine.cpio"'
}

src_compile() {
	# Generate module signing key
	if use module_sign; then
		${KERNEL_DIR}/scripts/sign-file -s build/signing_key.priv build/signing_key.x509 <<<""
	fi

	# Compat: the old ebuild was named coreos-kernel, but did not actually
	# build the kernel, just the modules.  So we preserve that behavior here.
	# TODO: this means the kernel is still built as part of the coreos-sources build.
	emake ${KERNEL_MAKE_OPTS} modules
}

# Cannot use kernel-2_src_test() because it assumes kernel has been built.
src_test() {
	emake ${KERNEL_MAKE_OPTS} modules_prepare scripts

	pushd "${S}/tools/testing/selftests" >/dev/null || die
	# x86 has some additional tests
	if [[ "${ARCH}" == "x86" || "${ARCH}" == "amd64" ]]; then
		# requires root
		local -a exclude_x86_tests=(
			x86
		)
		emake TARGETS="$(printf '%s\n' */ | grep -Ev "($(IFS='|'; echo "${exclude_x86_tests[*]}"))" | tr '\n' ' ')"
	elif [[ "${ARCH}" == "arm64" ]]; then
		local -a exclude_arm64_tests=(
			arm64/tags  # fails to build
			bpf  # requires root for most tests
			net  # requires root for most tests
		)
		emake TARGETS="$(printf '%s\n' */ | grep -Ev "($(IFS='|'; echo "${exclude_arm64_tests[*]}"))" | tr '\n' ' ')"
	else
		die "Unsupported architecture: ${ARCH}"
	fi
	popd >/dev/null || die

	# Upstream has a new script from v6.12 that we might be able to use:
	# https://github.com/torvalds/linux/commit/a5ad7ce90c9e7c29fdc5f82e3d5fc67cec6bb9cb
	# Currently it only supports x86 but if it matures for other
	# architectures we should consider switching to it.
	einfo "Running checkmodule to see that modules work"
	local modules=$(find "${S}" -name "*.ko")
	local tmpmod
	for tmpmod in ${modules}; do
		if /sbin/modinfo "${tmpmod}" &>/dev/null ; then
			einfo "modinfo ${tmpmod##*/} successful"
		else
			die "modinfo ${tmpmod##*/} failed"
		fi
	done
}

src_install() {
	install_kmod_src() {
		emake ${KERNEL_MAKE_OPTS} \
			INSTALL_MOD_PATH="${D}" modules_install
		# delete symlinks
		find "${D}" -type l -delete
		find "${D}" -name "*.ko*" -exec file {} \; | \
			grep -E "(gzip|xz) compressed" | \
			cut -d: -f1 | \
			sed 's/.ko\(.*\)/.ko/' | \
			xargs --no-run-if-empty rm
	}

	# Flatten the kernel module tree, moving all modules
	# into a single directory so they can be compressed more efficiently.
	install_kmod_src
	mkdir -p "${D}/lib/modules-uncompressed"
	find "${D}/lib/modules/${KV_FULL}" -name "*.ko" \
		-exec mv {} "${D}/lib/modules-uncompressed/" \;
	rmdir "${D}/lib/modules/${KV_FULL}"

	# Delete kernel source and build links, they are not useful in a container.
	rm -f "${D}/lib/modules/${KV_FULL}/source"
	rm -f "${D}/lib/modules/${KV_FULL}/build"

	# Compress modules
	xz --threads=0 --compress --extreme --lzma2 "${D}/lib/modules-uncompressed"/*.ko

	save_config build/.config
}
