from django.http import JsonResponse
from django.views.decorators.csrf import csrf_exempt

def health(request):
    return JsonResponse({"status":"ok"})

@csrf_exempt
def orders(request):
    # Placeholder: return a fake order list; in real usage, connect to DB/models
    return JsonResponse({"orders":[{"id":1,"status":"created"}]})

@csrf_exempt
def invoices(request):
    # Placeholder: return a fake invoice list; n8n can poll this endpoint
    return JsonResponse({"invoices":[{"id":1,"pdf_url":"http://django:8000/static/demo/invoice1.pdf"}]})
