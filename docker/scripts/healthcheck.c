// SPDX-FileCopyrightText: 2026 Sergio Bonatto
// SPDX-License-Identifier: MIT

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

enum {
	HEALTH_PORT = 8080,
	RESPONSE_CAPACITY = 4096,
};

static int send_all(int socket_fd, const char *data, size_t length)
{
	size_t sent = 0;

	while (sent < length) {
		ssize_t result = send(socket_fd, data + sent, length - sent, 0);

		if (result < 0 && errno == EINTR)
			continue;
		if (result <= 0)
			return -1;
		sent += (size_t)result;
	}

	return 0;
}

static int receive_response(int socket_fd, char *response, size_t capacity)
{
	size_t used = 0;

	while (used + 1 < capacity) {
		ssize_t result = recv(socket_fd, response + used, capacity - used - 1, 0);

		if (result < 0 && errno == EINTR)
			continue;
		if (result < 0)
			return -1;
		if (result == 0)
			break;
		used += (size_t)result;
	}

	response[used] = '\0';
	return (int)used;
}

int main(void)
{
	static const char request[] =
		"GET /healthz HTTP/1.1\r\n"
		"Host: localhost\r\n"
		"Connection: close\r\n"
		"\r\n";
	static const char expected_body[] = "ok\n";
	struct sockaddr_in address = {0};
	struct timeval timeout = {.tv_sec = 2, .tv_usec = 0};
	char response[RESPONSE_CAPACITY];
	char *body;
	int socket_fd;
	int response_length;
	int healthy = 0;

	socket_fd = socket(AF_INET, SOCK_STREAM, 0);
	if (socket_fd < 0)
		return 1;

	if (setsockopt(socket_fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) != 0)
		goto done;
	if (setsockopt(socket_fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) != 0)
		goto done;

	address.sin_family = AF_INET;
	address.sin_port = htons(HEALTH_PORT);
	if (inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) != 1)
		goto done;
	if (connect(socket_fd, (const struct sockaddr *)&address, sizeof(address)) != 0)
		goto done;
	if (send_all(socket_fd, request, sizeof(request) - 1) != 0)
		goto done;

	response_length = receive_response(socket_fd, response, sizeof(response));
	if (response_length <= 0)
		goto done;
	if (strncmp(response, "HTTP/1.1 200 ", 13) != 0 &&
	    strncmp(response, "HTTP/1.0 200 ", 13) != 0)
		goto done;

	body = strstr(response, "\r\n\r\n");
	if (body == NULL)
		goto done;
	body += 4;

	if (strcmp(body, expected_body) == 0)
		healthy = 1;

done:
	(void)close(socket_fd);
	return healthy ? 0 : 1;
}
