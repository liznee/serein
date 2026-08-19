package api

import (
	"reflect"
	"sort"
	"testing"
)

func TestConnectedRelayProjectsUsesLiveRelayClients(t *testing.T) {
	hub := &wsHub{
		relayClients: make(map[*wsClient]bool),
	}
	hub.relayClients[&wsClient{project: "test1", relayReceiver: true}] = true
	hub.relayClients[&wsClient{project: "serein", relayReceiver: true}] = true
	hub.relayClients[&wsClient{project: "test1", relayReceiver: true}] = true
	hub.relayClients[&wsClient{project: "", relayReceiver: true}] = true

	got := hub.connectedRelayProjects()
	sort.Strings(got)
	want := []string{"serein", "test1"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("connectedRelayProjects() = %v, want %v", got, want)
	}
}

func TestConnectedRelayProjectsDropsClosedRelay(t *testing.T) {
	hub := &wsHub{
		relayClients: make(map[*wsClient]bool),
	}
	client := &wsClient{project: "test1", relayReceiver: true}
	hub.relayClients[client] = true
	delete(hub.relayClients, client)

	got := hub.connectedRelayProjects()
	if len(got) != 0 {
		t.Fatalf("connectedRelayProjects() = %v, want empty", got)
	}
}
