from django.contrib import admin
from django.urls import path
from saas.views import health, orders, invoices

urlpatterns = [
    path("admin/", admin.site.urls),
    path("health/", health),
    path("api/orders", orders),
    path("api/invoices", invoices),
]
