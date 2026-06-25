/* Probe: does this platform provide the IPv6 APIs tcplib needs? */
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	struct sockaddr_in6 sin6;
	struct in6_addr a6;
	struct addrinfo hints, *res = NULL;
	int s;

	memset(&hints, 0, sizeof(hints));
	hints.ai_family = AF_INET6;
	hints.ai_socktype = SOCK_STREAM;
	(void)getaddrinfo("::1", "1984", &hints, &res);
	if (res) freeaddrinfo(res);

	(void)inet_pton(AF_INET6, "::1", &a6);
	(void)IN6_IS_ADDR_V4MAPPED(&a6);
	memset(&sin6, 0, sizeof(sin6));
	sin6.sin6_family = AF_INET6;

	s = socket(AF_INET6, SOCK_STREAM, 0);
	if (s >= 0) close(s);
	return 0;
}
