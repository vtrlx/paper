/* cheveret.c — Startup and support code for Cheveret. */

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

/* This doesn't need to be a header file. */
int luaopen_inotify(lua_State *L);

#define VERSION "0.1.0-alpha"

static int
get_is_devel_lua(lua_State *L)
{
#ifdef DEVEL
	lua_pushboolean(L, 1);
#else
	lua_pushboolean(L, 0);
#endif
	return 1;
}

static int
get_app_id_lua(lua_State *L)
{
#ifdef DEVEL
	lua_pushstring(L, "ca.vlacroix.Cheveret.Devel");
#else
	lua_pushstring(L, "ca.vlacroix.Cheveret");
#endif
	return 1;
}

static int
get_app_ver_lua(lua_State *L)
{
#ifdef VERSION
	lua_pushstring(L, VERSION);
#else
#error("VERSION macro is not defined!")
#endif
	return 1;
}

static int
getcwd_lua(lua_State *L)
{
	char path[BUFSIZ] = {0};
	void *ptr;
	ptr = getcwd(path, BUFSIZ - 1);
	if (!ptr)
		return 0;
	lua_pushstring(L, path);
	return 1;
}

static int
forkcdexec_lua(lua_State *L)
/* Forks the process, changes directory the a certain given directory, and then executes a given shell command. This function is used mainly to open terminals and the file browser in the project folder. */
{
	const char *dir;
	const char *bin;
	char program[BUFSIZ] = {0};
	char *argv[4];
	dir = luaL_checkstring(L, 1);
	bin = luaL_checkstring(L, 2);
	if(!fork()) {
		strcpy(program, bin);
		argv[0] = "/usr/bin/sh";
		argv[1] = "-c";
		/* Running in sh(1) lets us avoid varargs. */
		argv[2] = program;
		argv[3] = NULL;
		if (!chdir(dir))
			execv("/usr/bin/sh", argv);
		/* If the chdir or execv fail, the thread needs to exit. Otherwise, chaotic and terrible things are likely to occur with Gtk. */
		exit(0);
	}
	return 0;
}

static const luaL_Reg chevlib[] = {
	{ "get_is_devel", get_is_devel_lua },
	{ "get_app_id", get_app_id_lua },
	{ "get_app_ver", get_app_ver_lua },
	{ "getcwd", getcwd_lua },
	{ "forkcdexec", forkcdexec_lua },
	/* sentinel item, marks the end of the array */
	{ NULL, NULL },
};

LUALIB_API int
luaopen_chevlib(lua_State *L)
{
	luaL_newlib(L, chevlib);
	return 1;
}

void
lua_prepare(lua_State *L, lua_CFunction f, const char *name)
/* Opens the given Lua library and inserts it into Lua's package.loaded table. This function is akin to calling require 'name' in Lua without capturing the result — simply preloading the package for a future require() where the result actually does get captured.
The main purpose of this is to avoid exporting a global variable from C code, to prevent awkward namespace collisions.
The first parameter is the Lua state to call into. The second is the luaopen_ function to call, and the third is the name under which the library should be stored. */
{
	lua_getglobal(L, "package");
	lua_getfield(L, -1, "loaded");
	lua_remove(L, -2);
	lua_pushstring(L, name);
	f(L);
	lua_settable(L, -3);
	lua_remove(L, -1);
}

extern char _binary_cheveret_lc_start[];
extern char _binary_cheveret_lc_end[];

int
main(int argc, char *argv[])
{
	lua_State *L;
	const char *message;
	size_t cheveret_lc_len = ((size_t)&_binary_cheveret_lc_end) - ((size_t)&_binary_cheveret_lc_start);
	L = luaL_newstate();
	luaL_openlibs(L);
	lua_prepare(L, luaopen_chevlib, "chevlib");
	lua_prepare(L, luaopen_inotify, "inotify");
	switch (luaL_loadbuffer(L, _binary_cheveret_lc_start, cheveret_lc_len, "cheveret")) {
	case LUA_ERRSYNTAX:
		fprintf(stderr, "Failed to load Cheveret: embedded binary is malformed.\n");
		message = luaL_checkstring(L, -1);
		if (message)
			fprintf(stderr, "%s\n", message);
		return 1;
	case LUA_ERRMEM:
		fprintf(stderr, "Failed to load Cheveret: could not allocate memory.\n");
		return 2;
	case LUA_OK:
		break;
	}
	lua_call(L, 0, 0);
	return 0;
}
