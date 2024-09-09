function runExample(form) {
  let data = $(form).serialize();
  console.log('Ser data ' + data + '<<');
  let postUrl = form.dataset.postUrl;
  $.ajax({
    url: postUrl,
    method: 'POST',
    data: data,
    success: function (response) {
      console.log(response.ids);
      for (newjobid in response.ids) {
        console.log('id ' + response.ids[newjobid]);
        alert('job runs on localhost/tests/' + response.ids[newjobid]);
      }
      //fetchHtmlEntry(rowUrl + response.id, targetElement);
    },
    error: function (xhr, ajaxOptions, thrownError) {
      console.log(ajaxOptions);
      console.log(xhr);

      if (xhr.responseJSON.error) {
        console.log(xhr.responseJSON.error);
      } else {
        console.log(thrownError);
      }
    }
  });
  event.preventDefault();
}
