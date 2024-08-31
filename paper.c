/* paper.c — Startup and support code for Paper.
Copyright © 2024 Victoria Lacroix

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program.  If not, see <https://www.gnu.org/licenses/>. */

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

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
	lua_pushstring(L, "ca.vlacroix.Paper.Devel");
#else
	lua_pushstring(L, "ca.vlacroix.Paper");
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

static int argc;
static char **argv;

static int
get_cli_args_lua(lua_State *L)
/* Returns each argument given to the command line. */
{
	int i;
	for (i = 0; i < argc; ++i) {
		lua_pushstring(L, argv[i]);
	}
	return argc;
}

static int
forkexec_lua(lua_State *L)
/* Forks the process and then executes a given shell command. This function is used mainly to open the file browser. */
{
	const char *cmd;
	char program[BUFSIZ] = {0};
	char *args[4];
	cmd = luaL_checkstring(L, 1);
	if (!fork()) {
		strcpy(program, cmd);
		args[0] = "/usr/bin/sh";
		args[1] = "-c";
		/* Running in sh(1) lets us avoid breaking up parameters manually. */
		args[2] = program;
		args[3] = NULL;
		execv("/usr/bin/sh", args);
		/* If execv() fails, the thread needs to exit. Otherwise, chaotic and terrible things will occur with Gtk. */
		exit(0);
	}
	return 0;
}

static const luaL_Reg paperlib[] = {
	{ "get_is_devel", get_is_devel_lua },
	{ "get_app_id", get_app_id_lua },
	{ "get_app_ver", get_app_ver_lua },
	{ "get_cli_args", get_cli_args_lua },
	{ "forkexec", forkexec_lua },
	/* sentinel item, marks the end of the array */
	{ NULL, NULL },
};

extern char _binary_paper_bytecode_start[];
extern char _binary_paper_bytecode_end[];

int
main(int _argc, char **_argv)
{
	lua_State *L;
	const char *message;
	size_t paper_bytecode_len = ((size_t)&_binary_paper_bytecode_end) - ((size_t)&_binary_paper_bytecode_start);

	argc = _argc;
	argv = _argv;

	L = luaL_newstate();
	luaL_openlibs(L);
	lua_getglobal(L, "package");
	lua_getfield(L, -1, "loaded");
	lua_remove(L, -2);
	lua_pushstring(L, "paperlib");
	luaL_newlib(L, paperlib);
	lua_settable(L, -3);
	lua_remove(L, -1);

	switch (luaL_loadbuffer(L, _binary_paper_bytecode_start, paper_bytecode_len, "paper")) {
	case LUA_ERRSYNTAX:
		fprintf(stderr, "Failed to load Paper: embedded binary is malformed.\n");
		message = luaL_checkstring(L, -1);
		if (message)
			fprintf(stderr, "%s\n", message);
		return 1;
	case LUA_ERRMEM:
		fprintf(stderr, "Failed to load Paper: could not allocate memory.\n");
		return 2;
	case LUA_OK:
		break;
	default:
		fprintf(stderr, "Failed to load Paper: an unhandled error ocurred.\n");
		return -1;
	}

	lua_call(L, 0, 0);
	return 0;
}
